######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Raw::HostList;

use strict;
use warnings;
use base 'Chisel::Builder::Raw::Base';
use Date::Parse ();
use DBI;
use JSON;
use Log::Log4perl qw/ :easy /;
use Regexp::Chisel qw/:all/;
use Group::Client;

sub new {
    my ( $class, %rest ) = @_;

    my %defaults = (
        # Group::Client object
        group_client => undef,

        # Name of master tag
        range_tag => undef,

        # Maximum number of changes before validation will fail
        maxchange => undef,

        # Tag expansion cache
        cache_file => ':memory:',
    );

    my $self = { %defaults, %rest };
    die "Too many parameters, expected only " . join ", ", keys %defaults
      if keys %$self > keys %defaults;

    # group client
    if( !$self->{group_client} ) {
        LOGCROAK "Please pass in a Group::Client as 'group_client'";
    }

    # master tag
    if( !$self->{range_tag} ) {
        LOGCROAK "Please pass in a roles tag as 'range_tag'";
    }

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

sub fetch {
    my ( $self, $arg ) = @_;

    LOGDIE "unsupported arg [$arg]" unless $arg eq 'dump';
    LOGDIE "need master tag!" unless $self->{'range_tag'};

    INFO "Fetching host list from tag: $self->{range_tag}";

    # Open cache file
    my $dbh =
      DBI->connect( "dbi:SQLite:dbname=$self->{cache_file}", undef, undef, { PrintError => 0, RaiseError => 1 } );

    # Set up cache schema
    $dbh->do( <<'EOT' );
CREATE TABLE IF NOT EXISTS roles (
    id INT PRIMARY KEY,
    name BLOB NOT NULL UNIQUE,
    mtime INT NOT NULL,
    members BLOB NOT NULL
)
EOT

    # Prepare some useful statements
    my $sth_delete = $dbh->prepare("DELETE FROM roles WHERE id = ?");
    my $sth_insert = $dbh->prepare("INSERT INTO roles (name, mtime, members, id) VALUES(?,?,?,?)");
    my $sth_update = $dbh->prepare("UPDATE roles SET name = ?, mtime = ?, members = ? WHERE id = ?");

    # Partially load cache into memory
    my $cache = $dbh->selectall_hashref( "SELECT id, mtime FROM roles", "id" );

    # Find all roles tagged with "range_tag"
    my %roles_result =
      map { $_->{'id'} => $_ } @{ $self->{'group_client'}->tag( $self->{'range_tag'}, 'roles' )->{'roles'} };

    # Delete roles we don't care about anymore
    while( my ( $role_id, $role_data ) = each %$cache ) {
        if( !exists $roles_result{$role_id} ) {
            DEBUG "Removing cached members for stale role [$role_id]";
            $sth_delete->execute( $role_id );
        }
    }

    # Update new or changed roles
    my $json_enc = JSON->new;
    while( my ( $role_id, $role_data ) = each %roles_result ) {
        my $rolename = $role_data->{'ns'} . '.' . $role_data->{'name'};
        my $mtime    = Date::Parse::str2time( "$role_data->{mtime} UTC" );

        if( !$cache->{$role_id} ) {
            DEBUG "Fetching members for new role [$rolename:$role_id] (mtime $mtime)";
            my $rolemembers = $self->{'roles_client'}->role( $rolename, 'members' )->{'members'};
            $sth_insert->execute( $rolename, $mtime, $json_enc->encode( $rolemembers ), $role_id );
        } elsif( $cache->{$role_id}{'mtime'} < $mtime ) {
            DEBUG "Fetching members for updated role [$rolename:$role_id] (old mtime $cache->{$role_id}{mtime} < new mtime $mtime)";
            my $rolemembers = $self->{'roles_client'}->role( $rolename, 'members' )->{'members'};
            $sth_update->execute( $rolename, $mtime, $json_enc->encode( $rolemembers ), $role_id );
        }
    }

    # Pull role members from the cache
    my %members_want; # for deduping
    my $sth = $dbh->prepare( "SELECT members FROM roles" );
    $sth->execute;
    while( my ( $members ) = $sth->fetchrow_array ) {
        $members_want{ lc $_ } = 1 for @{ $json_enc->decode( $members ) };
    }

    # Disconnect from cache
    $dbh->disconnect;

    # Remove invalid hostnames, and sort (for consistency)
    my @members = sort grep { /^$RE_CHISEL_hostname\z/ } keys %members_want;

    INFO "Done fetching host list from tag: $self->{range_tag}";

    return join( "\n", @members ) . ( @members ? "\n" : "" );
}

sub validate {
    my ( $self, $arg, $new_txt, $old_txt ) = @_;

    LOGDIE "unsupported arg [$arg]" unless $arg eq 'dump';

    LOGDIE "$arg: blocked removal\n" if !defined $new_txt;

    # Allow anything if $old_txt is undefined (i.e. this is the very first import)
    # Main reason being if we don't let that through, there will be nothing to review
    # since doozer-checkout will not be able to commit anything
    return 1 if ! defined $old_txt;

    my %new = map { $_ => 1 } split /\n/, $new_txt;
    my %old = map { $_ => 1 } split /\n/, ( defined $old_txt ? $old_txt : '' );

    # Block if there are too many changes
    if( $self->{maxchange} && $self->{maxchange} > 0 ) {
        my $added   = scalar grep { !$old{$_} } keys %new;
        my $removed = scalar grep { !$new{$_} } keys %old;
        my $changes = $added + $removed;

        LOGDIE "$arg has too many changes ($changes > $self->{maxchange})\n"
          if $changes > $self->{maxchange};
    }

    return 1;
}

1;
