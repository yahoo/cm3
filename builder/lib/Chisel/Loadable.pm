######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Loadable;

# handy class for lazy-loading

use warnings;
use strict;
use Hash::Util ();
use Log::Log4perl qw/:easy/;

sub new {
    my ( $class, %rest ) = @_;

    my $loader = delete $rest{'loader'};

    my $self = {
        loader    => $loader,    # should be a code ref that returns a loaded "something"
        stuff     => undef,      # defined iff loading was successful (it's the thing we wanted to load)
        error     => undef,      # defined iff loading was unsuccessful (actually, it's the original error)
    };

    bless $self, $class;
    Hash::Util::lock_keys(%$self);
    return $self;
}

# checks if this thing is loaded or not
sub is_loaded {
    my ( $self ) = @_;
    return defined $self->{stuff} || defined $self->{error};
}

# has to actually load to know if it's good or not
sub is_good {
    my ( $self ) = @_;
    eval { $self->load; };
    return defined( $self->{stuff} ) ? 1 : undef;
}

# check what the error would be, if any (if none: undef)
sub error {
    my ( $self ) = @_;
    eval { $self->load; };
    if( defined $self->{stuff} ) {
        return undef;
    } else {
        my $err = $@;

        # remove stack traces and trailing whitespace
        $err =~ s/ at .+ line \d+.*//sg;
        $err =~ s/\s+$//g;

        return $err;
    }
}

# get the stuff
sub load {
    my ( $self ) = @_;

    if( defined $self->{error} ) {
        # re-throw the original error
        LOGDIE $self->{error};
    }

    if( ! defined $self->{stuff} ) {
        # Nuke loader once it's been used
        my $loader = $self->{loader};
        undef $self->{loader};

        # Load in an eval so we can set 'error' if something fails
        eval {
            my $stuff = $loader->();

            if( ! defined $stuff ) {
                # err... not ideal, let's die
                die "stuff came back undefined!\n";
            } else {
                $self->{stuff} = $stuff;
            }

            1;
        } or do {
            # unfortunate
            $self->{error} = $@;
            LOGDIE $self->{error};
        };
    }

    # this could be because stuff was defined
    # or because we fell through from a success above
    return $self->{stuff};
}

# unload stuff and loader, plus set error
sub unload {
    my ( $self ) = @_;

    undef $self->{loader};
    undef $self->{stuff};
    $self->{error} = 'Object was unloaded';
    return;
}

1;
