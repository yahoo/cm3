######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Engine::Walrus;

# this package is meant to map nodes onto transforms
#
# inputs:  list of tags + list of transforms + list of nodes
# outputs: nodes => buckets
#            (might be a smaller list of nodes, if we decide some nodes are not a good idea to build for)

use strict;
use warnings;
use Chisel::Builder::Group;
use Chisel::Builder::Group::Host;
use Chisel::Builder::Group::Roles;
use Chisel::Builder::Group::cmdbNode;
use Chisel::Builder::Group::cmdbNodeGroup;
use Chisel::Tag;
use Chisel::Metrics;
use Chisel::Loadable;
use Chisel::Transform;
use Regexp::Chisel qw/:all/;
use Carp;
use Digest::MD5 qw/md5_hex/;
use Log::Log4perl qw/:easy/;
use List::MoreUtils qw/any/;
use Hash::Util ();
use Scalar::Util ();
use YAML::XS ();

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # array of Chisel::Transform
        #   NOTE: will be converted into a lookup table later
        transforms => [],

        # array of Chisel::Tag
        #   NOTE: will be converted into a lookup table later
        tags => [],

        # if set, only build for nodes that are part of at least one tag
        require_tag => 0,

        # if set to an arrayref, all hosts must be in ANY of these groups (mostly a safety measure against roles.corp being weird)
        #   NOTE: will be converted into a lookup table later
        require_group => undef,

        # a Chisel::Builder::Group object used for mapping hosts to groups
        groupobj => undef,

        # Chisel::Metrics object for storing metrics
        metrics_obj => undef,
    };

    my $self = { %$defaults, %rest };

    # create objects that we need but weren't given to us
    if( !$self->{metrics_obj} ) {
        my ( $pkg, $file, undef ) = caller();
        TRACE "We weren't given a metrics object by package $pkg in file $file, creating dummy";
        $self->{metrics_obj} = Chisel::Metrics->new;
    }

    if( keys %$self > keys %$defaults ) {
        LOGDIE "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    # as promised, turn 'require_group', 'transforms', and 'tags' into lookup tables
    $self->{require_group} = { map { lc "$_" => "$_" } @{ $self->{require_group} } }
      if defined $self->{require_group};
    $self->{transforms} = { map { lc $_->name => $_ } @{ $self->{transforms} } };
    $self->{tags}       = { map { lc $_->name => $_ } @{ $self->{tags} } };

    # create empty host list
    $self->{hosts} = {};

    # most methods in this class will require the node => group mapping created by 'groupobj'
    # we're going to use a loader in 'hosts_groups_loader'

    my $weakself = $self;
    Scalar::Util::weaken($weakself);

    $self->{hosts_groups_loader} = Chisel::Loadable->new(
        loader => sub {
            # use $weakself->{groupobj} to associate all of these nodes with groups
            # we are going to figure out two things here:
            #   1. which nodes belong to which tags (since it's based on property)
            #   2. unfiltered list of transforms for each node

            # first, lock hosts so no new hosts can be added.
            Hash::Util::lock_keys( %{ $weakself->{'hosts'} } );

            # the list of required groups, or an empty list if it's not set
            my @require_group = defined $weakself->{require_group} ? ( values %{ $weakself->{require_group} } ) : ();

            DEBUG "host_transforms_loader: fetch with require_group = [@require_group]";

            # Keep track of which hosts have which groups
            my %host_groups;

            # We want hosts with the same group set to share an array
            # Use this tree to keep track of them
            my %groupset_tree;

            $weakself->{groupobj}->fetch(
                hosts  => [ keys %{ $weakself->{'hosts'} } ],
                groups => [
                    grep { !/^(?:DEFAULT|DEFAULT_TAIL|GLOBAL)$/ } ( map { $_->name } $weakself->tags, $weakself->transforms ),
                    @require_group
                ],
                cb => sub {
                    my ( $rhost, @rgroups ) = @_;

                    if( $host_groups{$rhost} ) {
                        $host_groups{$rhost}{n}--;
                    }

                    my @new_groupset
                        = $host_groups{$rhost}
                        ? sort( @{ $host_groups{$rhost}{groups} }, @rgroups )
                        : sort @rgroups;

                    my $node = \%groupset_tree;
                    for my $group (@new_groupset) {
                        $node = ( $node->{$group} ||= {} );
                    }

                    if( $node->{'f//'} ) {
                        $node->{'f//'}{n}++;
                    } else {
                        $node->{'f//'} = { n => 1, groups => \@new_groupset };
                    }

                    $host_groups{$rhost} = $node->{'f//'};
                },
            );

            DEBUG "host_transforms_loader: processing groups into tags and transforms";

            # Go through each groupset and convert groups -> transforms
            my $ngroupset = 0;
            my $search;
            $search = sub {
                my ($node) = @_;
                for my $out (keys %$node) {
                    if( $out eq 'f//' ) {
                        # Process this groupset
                        my $groupset = $node->{'f//'};

                        # Skip if no host actually uses this groupset
                        next if $groupset->{n} == 0;

                        # Get transform list for this groupset (by using a hash slice)
                        # Skip missing transforms, they were probably tags that have no matching transform (or possibly the require_group groups)
                        my @transforms = grep { defined $_ } @{ $weakself->{transforms} }{ map { lc $_ } @{$groupset->{groups}} };

                        # filter even further if this host has tags
                        my @tags = grep { defined $_ } map { $weakself->{'tags'}{ lc $_ } } ( 'GLOBAL', @{$groupset->{groups}} );
                        if( @tags ) {
                            my %transforms_ok;

                            for my $tag (@tags) {
                                $transforms_ok{$_} = 1 for $tag->match( @transforms );
                            }

                            @transforms = grep { $transforms_ok{$_} } @transforms;
                        }

                        # add DEFAULT, DEFAULT_TAIL if they exist
                        push @transforms, $weakself->{transforms}{'default'} if exists $weakself->{transforms}{'default'};
                        push @transforms, $weakself->{transforms}{'default_tail'} if exists $weakself->{transforms}{'default_tail'};

                        # respect $weakself->{require_tag} if set, means we should drop nodes if they have no non-GLOBAL tags
                        if( $weakself->{require_tag} and ! any { lc "$_" ne 'global' } @tags ) {
                            @transforms = ();
                        }

                        # respect $weakself->{require_group} if it's set, means we should drop nodes without at least one of those groups
                        elsif( defined $weakself->{require_group} and ! any { $weakself->{require_group}{ lc "$_" } } @{$groupset->{groups}} ) {
                            @transforms = ();
                        }

                        # replace old groupset hash with list of tags and transforms
                        %$groupset = ( transforms => \@transforms, tags => \@tags );

                        # increment count
                        $ngroupset ++;
                    } else {
                        # Keep searching
                        $search->($node->{$out});
                    }
                }
            };

            $search->(\%groupset_tree);

            DEBUG "host_transforms_loader: processed $ngroupset groupsets";

            return \%host_groups;
        }
    );

    bless $self, $class;

    # this class is complicated enough without worrying about random things stuffed into $self
    Hash::Util::lock_keys(%$self);
    Hash::Util::lock_value( %$self, $_ ) for keys %$self;

    return $self;
}

# add a host to the list of hosts we want to fetch transforms for
sub add_host {
    my ( $self, %args ) = @_;
    defined( $args{$_} ) or confess( "$_ not given" ) for qw/ host /;

    my $host  = $args{'host'};

    # reject weird-looking hostnames
    if( $host !~ /^$RE_CHISEL_hostname$/ ) {
        LOGDIE "Hostname is invalid: $host";
    }

    # create stub transforms entry for this $host
    if( ! exists $self->{'hosts'}{$host} ) {
        $self->{'hosts'}{$host} = 1;
    }

    return 1;
}

sub host_tags {
    my ( $self, %args ) = @_;
    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/host/;

    my $host = $args{'host'};

    my $host_groups = $self->{hosts_groups_loader}->load->{$host};
    if( $host_groups ) {
        return @{$host_groups->{tags}};
    } else {
        return;
    }
}

sub host_transforms {
    my ( $self, %args ) = @_;
    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/host/;

    my $host = $args{'host'};

    my $host_groups = $self->{hosts_groups_loader}->load->{$host};
    if( $host_groups ) {
        return @{$host_groups->{transforms}};
    } else {
        return;
    }
}

# accessors
sub metrics    { return shift->{metrics_obj} }
sub range      { return keys %{shift->{hosts}} }
sub tags       { return values %{ shift->{tags} } }
sub transforms { return values %{ shift->{transforms} } }

1;
