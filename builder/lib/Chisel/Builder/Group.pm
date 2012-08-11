######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Group;

# Utility class that assigns hosts to tokens like "group_role/foo" and "cmdb_property/bar"
#
# It does this in batches, as in, you provide it a list of hosts and list of tokens and it
# maps them for you. The reason for this is that group plugins tend to have nice optimizations
# available at scale, and they can take best advantage of this if they know exactly what you need.

use warnings;
use strict;
use Hash::Util ();
use Log::Log4perl qw/ :easy /;
use Regexp::Chisel qw/ :all /;
use Carp;

sub new {
    my ( $class, %rest ) = @_;

    my $self = {
        plugins     => {},                   # e.g. $plugins{'cmdb_property'} = object that handles cmdb_property
        metrics_obj => $rest{metrics_obj},
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );

    return $self;
}

# takes a group plugin and registers it with us
#
# returns number of functions registered in scalar context
#      or list of function names in list context
sub register {
    my ( $self, %args ) = @_;
    defined( $args{$_} )
      or confess( "$_ not given" )
      for qw/plugin/;

    my $function_sub = $args{plugin}->can( 'impl' )
      or LOGDIE "Invalid plugin, no 'impl' method";

    my @functions = $function_sub->( $args{plugin} )
      or LOGDIE "plugin has no group types implemented";

    foreach my $f ( @functions ) {
        WARN "Group type is already registered, replacing old one: $f"
          if $self->{plugins}{$f};

        TRACE "Registering plugin for $f (ref=$args{plugin})";

        $self->{plugins}{$f} = $args{plugin};
    }

    return @functions;
}

# split a group name like 'cmdb_property/foo' into 'cmdb_property' and 'foo'
# returns an empty list (doesn't die!) if the name is unparseable
sub parse {
    my ( $self, $key ) = @_;

    LOGDIE "no key provided" if !defined $key;

    if( $key =~ m!^($RE_CHISEL_transform_type)/($RE_CHISEL_transform_key)\z! ) {
        return ( $1, $2 );
    } else {
        return ();
    }
}

# inputs: list of hosts, list of groups, callback that receives hostname => groupname mapping
# outputs: none other than calling your callback
# guarantees:
#   - will not return nodes/groups you didn't pass in
#   - preserves case of nodes/groups you pass in, even though groups are case-insensitive
sub fetch {
    my ( $self, %args ) = @_;
    defined( $args{$_} )
      or confess( "$_ not given" )
      for qw/ hosts groups cb /;

    # Build an index of lc hostname -> correct case hostname
    # Just in case a plugin returns all uppercase or something, we still want it to map
    # to the right hostname.
    my %host_lookup = map { lc $_ => $_ } @{ $args{hosts} };

    # We're going to parcel the requests out based on which plugins handle which groups.
    my %plugin_groups;

    for my $group ( @{ $args{groups} } ) {
        my ( $f, $arg ) = $self->parse( lc $group )
          or LOGDIE "Badly formatted group [$group]";

        my $plugin_ref = $self->{plugins}{$f}
          or LOGDIE "No plugin for group [$group]";

        # Remember that $group is associated with plugin for $f.
        # Also remember the correct case for lc $group so we can restore it later.

        # Since we're storing plugins as references to objects, we can
        # do numeric comparison on the references to clump groups together.

        $plugin_groups{ 0 + $plugin_ref }{ lc $group } = $group;
    }

    # Let's farm out the requests now
    foreach my $plugin_addr ( keys %plugin_groups ) {
        # Convert numeric reference to actual object
        my ( $plugin ) = grep { ( 0 + $_ ) == $plugin_addr } values %{ $self->{plugins} };

        # And call the plugin
        $plugin->fetch(
            hosts  => $args{hosts},
            groups => [ values %{ $plugin_groups{$plugin_addr} } ],
            cb     => sub {
                my ( $rhost, @rgroups ) = @_;

                if( ! defined $rhost ) {
                    LOGDIE "Invalid callback";
                }

                # Restore case of $rhost. Also check that it was part of our original set.
                $rhost = $host_lookup{ lc $rhost };

                # Restore case of all @rgroups. Also check if they were part of our original set.
                @rgroups = grep { defined $_ } map { $plugin_groups{$plugin_addr}{ lc $_ } } @rgroups;

                if( $rhost and @rgroups ) {
                    $args{cb}->( $rhost, @rgroups );
                }
            }
        );
    }

    return;
}

# Wrapper around fetch that provides the old API
sub group {
    my ( $self, %args ) = @_;

    my %result;
    $self->fetch(
        hosts  => $args{nodes},
        groups => $args{groups},
        cb     => sub {
            my ( $rhost, @rgroups ) = @_;
            $result{$rhost}{$_} = 1 for @rgroups;
        },
    );
    $result{$_} = [ keys %{ $result{$_} } ] for keys %result;
    return \%result;
}

1;
