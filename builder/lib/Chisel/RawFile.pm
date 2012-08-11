######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::RawFile;

# Chisel::RawFile represents a single raw file.
# Each one has at least a name and contents, and possibly other details.

use strict;
use warnings;
use Digest::SHA1 ();
use Encode ();
use Hash::Util ();
use Log::Log4perl qw/ :easy /;
use Regexp::Chisel qw/ :all /;

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # name of this raw file, like "motd" or "cmdb_usergroup/xxx"
        name        => undef,

        # data for this raw file
        # if undef, means this object is a placeholder for a nonexistent file
        data        => undef,

        # time that this raw file was last fetched
        # the purpose is to prevent over-fetching
        ts          => 0,

        # potential new data for this raw file, which failed validation at some point
        # upon review, will be copied over to "data" and undef'd
        data_pending => undef,
    };

    my $self = { %$defaults, %rest };
    if( keys %$self > keys %$defaults ) {
        LOGDIE "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    # 'name' needs a certain format
    if( !defined $self->{name} || $self->{name} !~ /^$RE_CHISEL_raw\z/ ) {
        LOGDIE "raw 'name' is not well-formatted: $self->{name}";
    }

    # 'ts' must be a number
    if( !defined $self->{ts} || $self->{ts} !~ /^\d+\z/ ) {
        LOGDIE "raw 'ts' is not well-formatted: $self->{ts}";
    } else {
        # convert from string to int, if we were constructed with a string
        $self->{ts} = int($self->{ts});
    }

    for my $field ( qw/data data_pending/ ) {
        my $blob_field = $field;
        $blob_field =~ s/data/blob/;

        if( defined $self->{$field} ) {
            # If data fields are provided as perl unicode strings, encode them to UTF-8
            if( utf8::is_utf8( $self->{$field} ) ) {
                $self->{$field} = Encode::encode( "UTF-8", $self->{$field}, Encode::FB_CROAK );
            }

            # Compute sha1 of data fields (in the git style)
            $self->{$blob_field} =
              lc Digest::SHA1::sha1_hex( "blob " . ( length $self->{$field} ) . "\0" . $self->{$field} );
        } else {
            $self->{$blob_field} = undef;
        }
    }

    bless $self, $class;
    Hash::Util::lock_hash( %$self );
    return $self;
}

# return the identifier for this raw file
# something like: foo/bar@4f097857906bbe2c2b8a9f5bc19f01506b1ac906
# this is unique based on the rawfile name/data pair
# will be undef if data is undef
sub id {
    my ( $self ) = @_;

    if( ! defined $self->{'blob'} ) {
        return undef;
    } else {
        return $self->{'name'} . "@" . $self->{'blob'};
    }
}

# return $self->data, but possibly decoded into perl's internal unicode format
# if it can't be decoded, just return raw bytes.
sub decode {
    my ( $self ) = @_;

    # pass-through undef
    if( !defined $self->{'data'} ) {
        return undef;
    }

    # check if data is UTF-8
    my $data_decode = eval {
        Encode::decode( "UTF-8", $self->data, Encode::FB_CROAK );
    };

    # if that succeeded, use it. else return $self->data unmolested.
    return defined $data_decode ? $data_decode : $self->{'data'};
}


sub name         { shift->{name} }
sub blob         { shift->{blob} }
sub data         { shift->{data} }
sub ts           { shift->{ts} }
sub blob_pending { shift->{blob_pending} }
sub data_pending { shift->{data_pending} }

1;
