######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Group::CMDBNodeGroup;

use strict;
use warnings;
use Log::Log4perl qw/ :easy /;
use CMDB::Client;

sub new {
    my ( $class, %rest ) = @_;

    my %defaults = (
        # CMDB::Client object
        c => undef,
    );

    my $self = { %defaults, %rest };
    die "Too many parameters, expected only " . join ", ", keys %defaults
      if keys %$self > keys %defaults;

    # cmdb client
    if( !$self->{c} ) {
        LOGCROAK "Please pass in a CMDB::Client as 'c'";
    }

    bless $self, $class;
}

sub impl {
    qw/ cmdb_nodegroup /;
}

sub fetch {
    my ( $self, %args ) = @_;

    foreach my $group ( @{ $args{groups} } ) {
        if( $group =~ m{^cmdb_nodegroup/((?:[\w\d][^\.\s]*\.?)+)\.([\w\d\-]+)\.([\w\d\-]+)$} ) {
            my ( $name, $property, $country ) = ( $1, $2, $3 );

            DEBUG "Calling NodeGroup.GetMembers for name=$name property=$property country=$country";

            # query CMDB
            my @nodes;

            eval {
                @nodes = $self->{c}->NodeGroupGetMembers(
                    name     => $name,
                    property => $property,
                    country  => $country,
                );

                1;
            } or do {
                # the "ok" error is if the nodegroup is not found in cmdb, which may happen.
                # try to fail in other cases.

                unless( "$@" =~ /Unknown node group/ && $self->{c}->http_error->code == 404 ) {
                    die "$@\n";
                }
            };

            # just in case cmdb loses its mind
            if( grep { !$_->{node} } @nodes ) {
                LOGDIE "no 'node' returned by NodeGroup.GetMembers";
            }

            # call back for the nodes we care about
            $args{cb}->( $_->{node}, $group ) for @nodes;
        } elsif( $group =~ m{^cmdb_nodegroup/} ) {
            # bad format
            WARN "Ignoring badly formatted cmdb_nodegroup name: $group";
        }
    }

    return;
}

1;
