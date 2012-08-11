######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Group::Host;

use strict;
use warnings;

sub new {
    bless {}, shift;
}

sub impl {
    qw/ host /;
}

sub fetch {
    my ( $self, %args ) = @_;

    my @ret;
    my %host_has_group;

    for my $group ( @{ $args{groups} } ) {
        if( $group =~ m!^host/(.+)\z! ) {
            $host_has_group{lc $1} = 1;
        }
    }

    for my $host ( @{ $args{hosts} } ) {
        if( $host_has_group{lc $host} ) {
            $args{cb}->( $host, "host/$host" );
        }
    }

    return;
}

1;
