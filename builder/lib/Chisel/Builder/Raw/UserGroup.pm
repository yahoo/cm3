######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Raw::UserGroup;

use strict;
use warnings;
use base 'Chisel::Builder::Raw::Base';
use Log::Log4perl qw/ :easy /;
use cmdb::Client;

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
        LOGCROAK "Please pass in a CMsDB::Client as 'c'";
    }

    TRACE sprintf "init url=%s user=%s", $self->{c}{host}, $self->{c}{user};

    bless $self, $class;
    Hash::Util::lock_keys(%$self);
    return $self;
}

sub fetch {
    my ( $self, $arg ) = @_;

    TRACE "cmdb_usergroup: looking for $arg";

    # the result will go in here
    my @users;

    # cmdb can have multiple groups with the same name but different types
    # this is the order we prefer to use in case of conflict
    my %group_order = (
        'cmdb' => 1,
        'ilist' => 2,
        'igor'  => 3,
    );

    # find all user groups matching this name with acceptable types
    my @groups;

    eval {
        @groups = $self->{c}->UserGroupsFind( name => $arg, match_type => 'exact', type => [ keys %group_order ], without_pagination => 1 );
        1;
    } or do {
        # Convert "No UserGroup(s) Found" to return undef, but die on other errors
        if( "$@" =~ /No UserGroup\(s\) Found/ ) {
            ERROR "No UserGroup(s) Found ($arg)";
            return undef;
        } else {
            die "$@\n";
        }
    };

    # get the best one based on the priority order in %group_order
    my ( $group ) =
      sort { $group_order{ $a->{'type'} } <=> $group_order{ $b->{'type'} } }
      grep { $group_order{ $_->{'type'} } }
      @groups;

    if( $group && ( my $group_id = $group->{'id'} ) ) {
        # log message
        TRACE "cmdb_usergroup: looked for $arg, found " . join( ", ", map { "$_->{id}:$_->{name}:$_->{type}" } @groups ) . " (using $group_id)";

        # pull the users out of this group

        eval {
            @users = map { $_->{username} } $self->{c}->UserGroupMembers( id => $group_id );
            1;
        } or do {
            # Suppress "No members found" -- this can happen -- but die on other errors
            unless( "$@" =~ /No members found/ ) {
                die "$@\n";
            }
        };

        # just in case
        die "cmdb gave us a usergroup without users!\n" if grep { ! $_ } @users;

        # filter out anything but normal-looking user names (emails, for example)
        # also sort users by username
        @users = sort grep { /^[\w\-]+$/ } @users;
    } else {
        # UserGroups.Find returned, but none of the groups looked OK?
        # Something's wrong, since we were filtering for that.
        die "UserGroups.Find returned unusable groups for [$arg]";
    }

    return join("\n", @users) . ( @users ? "\n" : "" );
}

1;
