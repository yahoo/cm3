######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Group::CMDBNode;

use strict;
use warnings;

use DBI;
use JSON::XS;
use Log::Log4perl qw/ :easy /;
use CMDB::BulkQuery::SQLite;
use CMDB::Client;

sub new {
    my ( $class, %rest ) = @_;

    my %defaults = (
        # CMDB::Client object
        turbo      => 0,
        c          => undef,
        cache_file => undef,
    );

    my $self = { %defaults, %rest };
    die "Too many parameters, expected only " . join ", ", keys %defaults
      if keys %$self > keys %defaults;

    # cmdb client
    if( !$self->{c} ) {
        LOGCROAK "Please pass in a CMDB::Client as 'c'";
    }

    # cache file for CMDB::BulkQuery
    if( !$self->{cache_file} ) {
        LOGCROAK "Please pass in a cache file path as 'cache_file'";
    }

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

sub impl {
    qw/ cmdb_site cmdb_property cmdb_profile /;
}

sub fetch {
    my ( $self, %args ) = @_;
    if( $self->{turbo} ) {
        $self->fetch_turbo( %args );
    } else {
        $self->fetch_oldstyle( %args );
    }
}

sub fetch_turbo {
    my ( $self, %args ) = @_;

    DEBUG "fetch_turbo starting";

    # Update cache_file using CMDB::BulkQuery
    my $bq = CMDB::BulkQuery::SQLite->new(
        cmdb_client => $self->{'c'},
        fields       => [ "status", "type", "site", "property" ],
    );

    $bq->fetch( file => $self->{'cache_file'} );

    # Read the SQLite file we just updated
    my $json_enc = JSON->new;
    my $dbh =
      DBI->connect( "dbi:SQLite:dbname=$self->{cache_file}", undef, undef, { PrintError => 0, RaiseError => 1 } );
    my $sth = $dbh->prepare( "SELECT entity, data FROM cmdb_sync" );
    $sth->execute;

    while( my ( $node_id, $node_json ) = $sth->fetchrow_array ) {
        my $node_data = $json_enc->decode( $node_json );

        # skip nodes we have zero interest in
        next unless $node_data->{'status'} eq 'active' || $node_data->{'status'} eq 'pending';
        next unless $node_data->{'type'} eq 'host' || $node_data->{'type'} eq 'vm';

        my $node_groups = $self->_groups_from_node( $node_data );
        $args{cb}->( $node_data->{name}, @$node_groups );
    }

    $dbh->disconnect;

    DEBUG "fetch_turbo done";

    return;
}

sub fetch_oldstyle {
    my ( $self, %args ) = @_;

    my $nodes = $args{nodes};
    my $groups = $args{groups};

    # here we go

    # it's significantly faster to use Nodes.Find in batches of 1000 than to use Node.Get
    my $batch_size = 1000;

    # keep track of how many responses we get so we can log it later
    my $nodes_responded = 0;

    DEBUG "Calling Nodes.Find (" . ( scalar @$nodes ) . " nodes total)";

    for( my $start = 0 ; $start < @$nodes ; $start += $batch_size ) {
        my $end = $start + $batch_size - 1;
        $end = @$nodes - 1 if $end >= @$nodes;

        my @nodes_found;

        eval {
            @nodes_found = $self->{c}->NodesFind(
                name               => [ @$nodes[ $start .. $end ] ],
                without_pagination => 1,
                fields             => [ "site", "property" ],
                status => [ "active", "pending" ],
                type   => [ "host",   "vm" ],
            );

            $nodes_responded += @nodes_found;

            1;
        } or do {
            # the "ok" error is if these hosts are not found in cmdb, which may happen.
            # try to fail in other cases.

            unless( "$@" =~ /No Node/ && $self->{c}->http_error->code == 404 ) {
                die "$@\n";
            }
        };

        # process the nodes we found by adding them to site, property, profile groups

        DEBUG sprintf "Got a response from Nodes.Find for %d/%d nodes in batch %d-%d / %d",
          ( scalar @nodes_found ),
          ( $end - $start + 1 ),
          $start + 1,
          $end + 1,
          ( scalar @$nodes );

        foreach my $node_found ( @nodes_found ) {
            # call back for these nodes
            my $node_groups = $self->_groups_from_node( $node_found );
            $args{cb}->( $node_found->{name}, @$node_groups );
        }
    }

    return;
}

# helper for both fetch_turbo and fetch_oldstyle
# prevents writing this logic in two places
sub _groups_from_node {
    my ( $self, $node_data ) = @_;

    my $result = [];

    my %fields = (
        'site'        => 'cmdb_site',
        'property'    => 'cmdb_property',
        'profile' => 'cmdb_profile',
    );


    # update cmdb_property, cmdb_site, cmdb_profile
    foreach my $field ( keys %fields ) {

        my $value = $node_data->{$field};
        next if !$value;

        push @$result, "$fields{$field}/$value";
    }

    return $result;
}

1;
