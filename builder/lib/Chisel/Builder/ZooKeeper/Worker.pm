######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::ZooKeeper::Worker;

use strict;

use base 'Chisel::Builder::ZooKeeper::Base';

use JSON::XS ();
use Log::Log4perl qw/:easy/;
use Net::ZooKeeper qw/:node_flags :errors :acls/;
use URI::Escape qw/uri_escape uri_unescape/;

use Regexp::Chisel qw/:all/;

# See Chisel::Builder::ZooKeeper::Base for ZooKeeper layout

sub new {
    my ( $class, %args ) = @_;

    if( !$args{'worker'} ) {
        LOGDIE "'worker' is required";
    }

    $class->SUPER::new(
        zkh             => $args{'zkh'},
        connect         => $args{'connect'},
        session_timeout => 30000,
        worker          => $args{'worker'},
        advertised      => [],
    );
}

sub can_advertise {
    my ( $self ) = @_;
    return $self->register("w-" . $self->{worker});
}

sub name {
    my ( $self ) = @_;
    return $self->{'worker'};
}

sub advertise {
    my ( $self, %args ) = @_;

    my $worker = $self->{'worker'};

    if( !$self->can_advertise ) {
        LOGCONFESS "advertise: Could not register advertisements for worker [$worker]";
    }
    
    DEBUG "advertise: Starting for worker [$worker]";

    # current advertisement list
    my @hosts1 = @{ $self->{'advertised'} };

    # new advertisement list
    my @hosts2 = sort @{ $args{'hosts'} };

    # hosts to delete + add
    my @hostsdel;
    my @hostsadd;

    my $host1 = 0;    # position in @hosts1 (current advertisement list)
    my $host2 = 0;    # position in @hosts2 (new advertisement list)

    while( $host2 < @hosts2 ) {
        if( $host1 < @hosts1 and $hosts1[$host1] eq $hosts2[$host2] ) {
            # host1 == host2, move both pointers
            $host1++;
            $host2++;
        } elsif( $host1 < @hosts1 and $hosts2[$host2] gt $hosts1[$host1] ) {
            # host2 > host1, means we need to remove host1
            push @hostsdel, $hosts1[$host1];

            # now move to the next host1
            $host1++;
        } else {
            # host2 < host1, means we need to add host2
            push @hostsadd, $hosts2[$host2];

            # now move to the next host2
            $host2++;
        }
    }

    # anything left in @hosts1 needs to be removed
    if( $host1 < @hosts1 ) {
        push @hostsdel, @hosts1[$host1..$#hosts1];
    }

    # first, remove old advertisement nodes
    DEBUG "advertise: Removing stale advertisement nodes for worker [$worker]";
    foreach my $hostdel ( @hostsdel ) {
        $self->_zk_delete( "/h/$hostdel/$worker" );
    }

    # next, run the user's callback, if provided
    if( $args{'callback'} ) {
        DEBUG "advertise: Running user callback";
        $args{'callback'}->();
    }

    # last, create new advertisement nodes
    DEBUG "advertise: Creating new advertisement nodes";
    foreach my $hostadd ( @hostsadd ) {
        $self->_zk_create( "/h/$hostadd/$worker", '', flags => ZOO_EPHEMERAL, acl => ZOO_OPEN_ACL_UNSAFE );
    }

    # update cached advertisement list
    $self->{'advertised'} = \@hosts2;

    INFO "advertise: Done updating advertisement nodes for worker [$worker]";

    return 1;
}

# get/set report for some host
# XXX - need to clean this up periodically
# XXX - this does *not* mean when the node is removed from /h
# XXX - since we might have reports for hosts we're not serving configs for
sub report {
    my ( $self, $host, $report ) = @_;

    if( defined $report ) {
        # Set report for $host to $report

        DEBUG "report: writing report for $host";

        my $json = JSON::XS::encode_json( $report );

        if( $self->_zk_exists( "/hr/$host" ) ) {
            # XXX - can have a race if the node is deleted between the exists + set
            $self->_zk_set( "/hr/$host", $json );
        } else {
            $self->_zk_create( "/hr/$host", $json, acl => ZOO_OPEN_ACL_UNSAFE );
        }

        # Return true
        return 1;
    } else {
        # Get report for $host

        DEBUG "report: retrieving report for $host";

        my $json = $self->_zk_get( "/hr/$host" );
        if( defined $json ) {
            return JSON::XS::decode_json( $json );
        } else {
            return undef;
        }
    }
}

# get all reports for all hosts
# XXX - slowballs
sub reports {
    my ( $self ) = @_;

    my @hosts = $self->_zk_get_children( "/hr" );

    my %reports;
    foreach my $h (@hosts) {
        my $json = $self->_zk_get("/hr/$h");
        $reports{$h} = JSON::XS::decode_json($json);
    }

    return \%reports;
}

1;
