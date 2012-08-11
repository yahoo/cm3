######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Group::Roles;

use strict;
use warnings;

use DBI;
use JSON;
use Log::Log4perl qw/ :easy /;
use Group::Client;

sub new {
    my ( $class, %rest ) = @_;

    my %defaults = (
        # Group::Client object
        c          => undef,
        threads    => 1,
        cache_file => undef,
        turbo    => 0,
    );

    my $self = { %defaults, %rest };
    die "Too many parameters, expected only " . join ", ", keys %defaults
      if keys %$self > keys %defaults;

    # roles client
    if( !$self->{c} ) {
        LOGCROAK "Please pass in a Group::Client as 'c'";
    }

    bless $self, $class;
}

sub impl {
    qw/ group_role /;
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

    my $nodes = $args{hosts};
    my $groups = $args{groups};

    # Extract role names from @$groups

    my @roles;

    foreach my $g ( @$groups ) {
        if( $g =~ m!^group_role/(.+)\z!i ) {
            push @roles, lc $1;
        } else {
            # this is a serious error
            LOGDIE "Group [$g] is not a role!";
        }
    }

    # Use doozer-sync-roles to update host -> role mapping

    INFO "Spawning doozer-sync-roles";

    open my $to_sr, '|-', 'doozer', 'sync-roles', '-f', $self->{'cache_file'}, '-P', $self->{'threads'}
      or LOGDIE "can't spawn doozer-sync-roles: $!\n";

    print $to_sr JSON->new->encode( { 'hosts' => $nodes, 'roles' => \@roles } )
      or LOGDIE "can't print to doozer-sync-roles: $!\n";

    close $to_sr
      or LOGDIE "doozer-sync-roles failed (" . ( $! ? "errno=$!" : "status=$?" ) . ")\n";

    # Read out of the sqlite file we just updated

    INFO "Reading from SQLite cache in $self->{cache_file}";

    my $json_enc = JSON->new;
    my $dbh =
      DBI->connect( "dbi:SQLite:dbname=$self->{cache_file}", undef, undef, { PrintError => 0, RaiseError => 1 } );
    my $sth = $dbh->prepare( "SELECT name, roles FROM host WHERE roles IS NOT NULL" );
    $sth->execute;

    while( my ( $host, $roles_json ) = $sth->fetchrow_array ) {
        my $roles = $json_enc->decode( $roles_json );
        $args{cb}->( $host, map { "group_role/$_" } @$roles );
    }

    DEBUG "fetch_turbo done";

    return;
}

sub fetch_oldstyle {
    my ( $self, %args ) = @_;

    my $nodes = $args{nodes};
    my $groups = $args{groups};

    # it's significantly faster to query in batches; currently 200 is the max size
    my $batch_size = 200;

    # keep track of how many responses we get so we can log it later
    my $nodes_responded = 0;

    DEBUG "Fetching roles (" . ( scalar @$nodes ) . " nodes total)";

    for( my $start = 0; $start < @$nodes; $start += $batch_size ) {
        my $end = $start + $batch_size - 1;
        $end = @$nodes - 1 if $end >= @$nodes;

        my $nodes = $self->{c}->hostname( [ @$nodes[ $start .. $end ] ], "roles", lax => 1 );

        # roles_client may return a single hash if we sent it one argument [bug 2939660]
        $nodes = [ $nodes ] if ref $nodes eq 'HASH' && $start == $end;

        # roles_client may return undef if none of the hostnames are found [bug 3160229]
        # don't suppress this error, since undef might mean something worse is wrong, but at least display a useful message
        if( ! defined $nodes ) {
            LOGDIE "roles_client returned undef, which may mean that an entire batch of nodes was not in any roles. Sorry!";
        }

        # process the nodes we found by adding them to roles

        $nodes_responded += @$nodes;

        DEBUG sprintf "Got a response for %d/%d nodes in batch %d-%d",
            (scalar @$nodes),
            ($end - $start + 1),
            $start + 1,
            $end + 1;

        foreach my $rec ( @$nodes ) {
            $args{cb}->( $rec->{name}, map { "group_role/$_->{ns}.$_->{name}" } @{ $rec->{roles} } );
        }
    }

    return;
}

1;
