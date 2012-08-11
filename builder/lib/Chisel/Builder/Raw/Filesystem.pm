######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Raw::Filesystem;

use strict;
use warnings;
use base 'Chisel::Builder::Raw::Base';
use Cwd ();
use Log::Log4perl qw/ :easy /;

sub new {
    my ( $class, %rest ) = @_;

    my %defaults = (
        rawdir => undef,
    );

    my $self = { %defaults, %rest };
    die "Too many parameters, expected only " . join ", ", keys %defaults
      if keys %$self > keys %defaults;

    TRACE sprintf "init rawdir=%s", $self->{rawdir};

    # last_nonfatal_error is for the unit tests, to make sure various error
    # conditions are detected correctly
    $self->{last_nonfatal_error} = undef;

    bless $self, $class;
    Hash::Util::lock_keys(%$self);
    return $self;
}

# Read a file off the filesystem
sub fetch {
    my ( $self, $arg ) = @_;

    # clear last_nonfatal_error
    undef $self->{last_nonfatal_error};

    # make sure $arg was given
    if( !defined $arg || $arg eq '' ) {
        die "no file name provided";
    }

    # resolve the true path of rawdir, so we can compare it to the files requested
    die "rawdir not provided" if ! $self->{rawdir};
    my $rawdir = Cwd::realpath( $self->{rawdir} )
      or die "rawdir not real: $self->{rawdir}";

    # make sure this file exists, if it doesn't then the realpath check below will give a misleading error
    if( ! -f "$rawdir/$arg" ) {
        ERROR $self->{last_nonfatal_error} = "file does not exist: $arg";
        return undef;
    }

    # use Cwd::realpath to confirm that this path is inside rawdir (even considering symlinks and such)
    my $rawfile = Cwd::realpath( "$rawdir/$arg" );

    if( $rawdir ne substr $rawfile, 0, length $rawdir ) {
        ERROR $self->{last_nonfatal_error} = "unsafe pathspec: $arg";
        return undef;
    }

    TRACE "readraw: looked for $arg, using $rawfile";

    open my $fh, "<", $rawfile
      or die "open $rawfile: $!\n";
    my $contents = do { local $/; <$fh> };
    close $fh
      or die "close $rawfile: $!\n";

    return $contents;
}

sub last_nonfatal_error { shift->{last_nonfatal_error} }

1;
