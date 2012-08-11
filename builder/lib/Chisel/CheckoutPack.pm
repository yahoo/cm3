######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::CheckoutPack;

use warnings;
use strict;

use Hash::Util ();
use Log::Log4perl qw/:easy/;

use Chisel::CheckoutPack::Staged;

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # Location of checkout database
        filename => undef,
    };

    my $self = { %$defaults, %rest };
    if( keys %$self > keys %$defaults ) {
        LOGCROAK "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

sub filename {
    my ( $self, $filename ) = @_;
    if( @_ > 1 ) {
        $self->{filename} = $filename;
    } else {
        return $self->{filename};
    }
}

# Return Staged object based on extracting existing tarball into a temp directory
sub extract {
    my ( $self ) = @_;

    if( !defined $self->{filename} ) {
        LOGDIE "no 'filename' currently set";
    }

    my $stage = Chisel::CheckoutPack::Staged->new;

    if( -f $self->{filename} ) {
        system( "tar", "-xf", $self->{filename}, "-C", $stage->stagedir );
        if( $? ) {
            LOGDIE "tar -xf $self->{filename} failed!\n";
        }
    }

    return $stage;
}

# Write new tarball based on a particular directory
sub write_from_fs {
    my ( $self, $dirname ) = @_;

    DEBUG "Writing tarball: $self->{filename}";
    system "tar", "-cf", "$self->{filename}.$$", "-C", $dirname, ".";
    if( $? ) {
        unlink "$self->{filename}.$$";    # just in case
        LOGDIE "tar failed!\n";
    } else {
        rename "$self->{filename}.$$", "$self->{filename}"
          or die "rename $self->{filename}.$$ -> $self->{filename}: $!\n";
    }

    return;
}

1;
