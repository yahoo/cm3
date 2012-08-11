######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::Homedir;

use strict;

use base 'Chisel::TransformModel';

use Carp;
use Encode     ();
use YAML::XS   ();
use YAML::Tiny ();
use Regexp::Chisel qw/:all/;

sub new {
    my ( $class, %args ) = @_;
    $class->SUPER::new(
        ctx      => $args{'ctx'},
        contents => $args{'contents'},
        yaml     => {},
    );
}

sub text {
    my ( $self ) = @_;

    local $YAML::Tiny::Indent = 2;
    return YAML::Tiny::Dump( $self->{yaml} );
}

sub action_append {
    my ( $self, @args ) = @_;

    # this eval will make us appropriately follow the action spec (1 = good, undef = error)
    return eval {
        # yaml parser expects bytes that happen to be utf-8 encoded
        # not perl's internal utf8 strings
        my $append_yaml = join( "\n", @args ) . "\n";
        my $append_obj = YAML::XS::Load(
              utf8::is_utf8( $append_yaml )
            ? Encode::encode_utf8( $append_yaml )
            : $append_yaml
        );

        while( my ( $k, $v ) = each %$append_obj ) {
            push @{ $self->{'yaml'}{$k} }, @$v;
        }

        1;
    };
}

# same implementation as append
sub action_appendexact {
    my ( $self, @args ) = @_;
    $self->action_append( @args );
}

sub action_truncate {
    my ( $self ) = @_;
    $self->{'yaml'} = {};
    return 1;
}

sub action_addkey {
    my ( $self, @args ) = @_;

    if( @args == 1 ) {
        # we need to convert this to the 2-arg form
        my ( $k, $v ) = ( $args[0] =~ /^(\S+)\s+(.*)$/ )
          or die "could not unpack single argument in addkey\n";
        @args = ( $k, $v );
    }

    # must be nonzero and even-numbered (alternating key/value)
    if( !@args ) {
        die "no arguments in addkey\n";
    }

    if( @args % 2 ) {
        die "odd number of arguments in addkey\n";
    }

    if( grep { !defined $_ } @args ) {
        # all args must be defined
        die "undefined arguments in addkey\n";
    }

    # @args has alternating key/value, scan them here
    for( my $argi = 0 ; $argi < @args ; $argi += 2 ) {
        my ( $k, $v ) = @args[ $argi .. ( $argi + 1 ) ];
        push @{ $self->{'yaml'}{$k} }, $v;
    }

    return 1;
}

sub action_clearkey {
    my ( $self, @args ) = @_;

    if( !@args ) {
        die "no arguments in clearkey\n";
    }

    foreach my $k ( @args ) {
        if( defined $k && exists $self->{'yaml'}{$k} ) {
            delete $self->{'yaml'}{$k};
        }
    }

    return 1;
}

1;
