######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Overmind::Host;

use strict;

use Hash::Util ();
use Scalar::Util qw/ blessed weaken /;
use Log::Log4perl qw/ :easy /;

use Regexp::Chisel qw/ :all /;

sub new {
    my ( $class, %rest ) = @_;

    # $name -- like "foo.domain.com"

    my $name = $rest{'name'};

    if( $name !~ /^$RE_CHISEL_hostname\z/ ) {
        LOGCROAK "Invalid hostname [$name]";
    }

    # Here's the object
    my $self = {
        # Hostname
        name => $name,

        # Transformset object this host is currently using
        # May change from time to time
        transformset => undef,
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

# see constructor for meanings
sub name     { shift->{name} }

sub transformset {
    my ( $self, $transformset ) = @_;
    if( @_ > 1 ) {
        # need to keep transformset->{hosts} accurate
        if( defined $self->{transformset} ) {
            delete $self->{transformset}{hosts}{ $self->{name} };
        }

        # ditto
        if( defined $transformset ) {
            $transformset->{hosts}{ $self->{name} } = $self;
            weaken $transformset->{hosts}{ $self->{name} };
        }

        return $self->{transformset} = $transformset;
    } else {
        return $self->{transformset};
    }
}

sub clear {
    my ( $self ) = @_;
    $self->{transformset} = undef;
    return $self;
}

sub DESTROY {
    my ( $self ) = @_;

    # need to keep transformset->{hosts} accurate
    if( $self->{transformset} ) {
        delete $self->{transformset}{hosts}{ $self->{name} };
    }

    DEBUG "GC Host [$self->{name}]";
}

1;
