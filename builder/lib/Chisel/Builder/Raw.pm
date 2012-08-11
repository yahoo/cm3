######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Raw;

# Coordinates raw file inputs to the builder. Raw files are used by "include",
# "invokefor", "use", etc. It's also used by special actions like "passwd" (
# is imported as a raw file).
#
# This class works by mounting various Raw plugins (subclasses of Raw::Base) into
# a "filesystem". Traditionally the / mount point is the raw/ directory from svn.

use warnings;
use strict;
use Hash::Util ();
use Log::Log4perl qw/ :easy /;
use Chisel::RawFile;
use Chisel::Builder::Raw::Base;
use Chisel::Builder::Raw::DNSDB;
use Chisel::Builder::Raw::Filesystem;
use Chisel::Builder::Raw::Hash;
use Chisel::Builder::Raw::HostList;
use Chisel::Builder::Raw::Keykeeper;
use Chisel::Builder::Raw::Roles;
use Chisel::Builder::Raw::UserGroup;
use Regexp::Chisel qw/ :all /;
use Carp;

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        now         => undef,
    };

    my $self = { %$defaults, %rest };
    if( keys %$self > keys %$defaults ) {
        LOGDIE "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    $self->{mountpoints} = {};

    # last_nonfatal_error is for the unit tests, to make sure various error
    # conditions are detected correctly
    $self->{last_nonfatal_error} = undef;

    bless $self, $class;
    Hash::Util::lock_keys(%$self);
    return $self;
}

# what time is it?
sub now {
    my ( $self ) = @_;
    return defined $self->{now} ? $self->{now} : time;
}

sub mount {
    my ( $self, %args ) = @_;
    defined( $args{$_} )
      or confess( "$_ not given" )
      for qw/ plugin mountpoint /;

    my $plugin     = $args{plugin};
    my $mountpoint = $args{mountpoint};

    # make sure the mountpoint is a sensible name
    $mountpoint eq '/' || $mountpoint =~ m{^(/[A-Za-z][\w\.\-]*)+$}
      or confess "bad mountpoint: $mountpoint";

    # set it up
    $self->{mountpoints}{$mountpoint} = $plugin;

    # return $self for chaining
    return $self;
}

# find which plugin should read $key by searching mountpoints
# input: raw file name like "cmdb_usergroup/foo" or "bar/baz"
# output: ( $plugin, $relative_name ) like ( $ug_plugin, "foo" ) or ( $root_plugin, "bar/baz" )
sub find_plugin {
    my ( $self, $key ) = @_;

    # figure out what plugin to handle this with
    # the rule is basically longest prefix wins

    foreach my $mountpoint ( sort { length $b <=> length $a } keys %{ $self->{mountpoints} } ) {
        # in order to make the regex work out
        my $mountpoint_match = $mountpoint =~ m{/$} ? $mountpoint : "$mountpoint/";

        if( "/$key" =~ m{^\Q$mountpoint_match\E(.+)$} ) {
            # file name, relative to this mountpoint (e.g. "foo" for "cmdb_usergroup/foo")
            my $key_rel = $1;

            return ( $self->{mountpoints}{$mountpoint}, $key_rel );
        }
    }

    # could not figure it out

    return;
}

# for compatibility with old calling style
sub raw {
    my ( $self, %args ) = @_;
    my $obj = $self->readraw( $args{'key'} );
    if(defined $obj && defined $obj->data) {
        return $obj->data;
    } else {
        LOGCROAK "Raw file [$args{key}] could not be fetched!";
    }
}

# fetches and validates a single raw file, intended to be called as part of Checkout
# input: name of raw file. optionally, context => previous RawFile object to have this name
# output: RawFile object with data/ts filled in
sub readraw {
    my ( $self, $key, %args ) = @_;

    # clear last_nonfatal_error
    undef $self->{last_nonfatal_error};

    # Save $args{context} to reduce typing later
    my $context = $args{'context'};

    # Validate format
    if( $key !~ /^$RE_CHISEL_raw\z/ ) {
        $self->{last_nonfatal_error} = "Invalid raw file name [$key]";
        ERROR $self->{last_nonfatal_error};
        return undef;
    }

    # OK. $key is good, time to load it.
    TRACE "Loading raw file [$key]";

    # Remember the time, btw.
    my $now = $self->now;

    # Step 1. Figure out what plugin to handle this file with
    my ( $plugin, $key_rel ) = $self->find_plugin( $key );
    if( !$plugin ) {
        $self->{last_nonfatal_error} = "Can't find plugin for raw file name [$key]";
        ERROR $self->{last_nonfatal_error};
        return undef;
    }

    # Step 2. Check if a new file is needed
    if( $plugin->expiration > 0 ) {
        if(
            $context                                          # we have a previous context
            and $context->ts > 0                              # we have a previous timestamp
            and defined $context->data                        # we have previous contents
            and $context->ts + $plugin->expiration >= $now    # it has not expired yet
          )
        {
            # Old file is still good
            DEBUG "File [$key] is still good (previous timestamp " . $context->ts . ")";
            return $context;
        } else {
            # Old file is no good (or it might not exist)
            DEBUG "File [$key] needs to be fetched "
              . ( $context ? "(previous timestamp " . $context->ts . ")" : "(no previous context)" );
        }
    } else {
        # File is not cacheable (no listed expiration)
        DEBUG "File [$key] is not cached and needs to be fetched";
    }

    # Step 3. New file is needed. Fetch it.
    # fetch = undef means we want to remove this file
    TRACE "Fetching new version of file [$key]";
    my $new_contents = eval { $plugin->fetch( $key_rel ) };
    if( $@ ) {
        # Log the error, then re-die
        chomp( my $err_str = $@ );
        LOGDIE "Raw file [$key] could not be fetched! [error: $err_str]";
    }

    # Step 4. Validate new file against previous file (either or both may be undefined, that's ok).
    TRACE "Validating file [$key]";
    my $old_contents = $context ? $context->data : undef;
    my $validated = eval { $plugin->validate( $key_rel, $new_contents, $old_contents ) };
    if( !$validated ) {
        # Log the error, then continue
        chomp( my $err_str = $@ || '' );
        ERROR "Raw file [$key] could not be validated!" . ( $err_str ? " [error: $err_str]" : "" );
    }

    # Step 5. Decide what to return
    if( $validated ) {
        # Fetch and validation both OK: just return $new_contents (even if it's undef)
        return Chisel::RawFile->new(
            name         => $key,
            data         => $new_contents,
            data_pending => undef,
            ts           => $now,
        );
    } elsif( defined $new_contents ) {
        # Fetch OK, validation failed: return $old_contents but mark $new_contents for review
        return Chisel::RawFile->new(
            name         => $key,
            data         => $old_contents,
            data_pending => $new_contents,
            ts           => $now,
        );
    } else {
        # Fetch and validation both failed: return $old_contents with nothing marked for review, and scream
        ERROR "Raw file [$key] could not be fetched, and no previous version is available!"
          if !defined $old_contents;

        return Chisel::RawFile->new(
            name         => $key,
            data         => $old_contents,
            data_pending => undef,
            ts           => $now,
        );
    }
}

1;
