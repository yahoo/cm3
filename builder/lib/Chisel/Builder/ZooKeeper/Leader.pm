######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::ZooKeeper::Leader;

use strict;

use base 'Chisel::Builder::ZooKeeper::Base';

use Digest::MD5 ();
use JSON::XS    ();
use List::MoreUtils qw/any firstval/;
use Log::Log4perl qw/:easy/;
use Net::ZooKeeper qw/:node_flags :errors :acls/;
use URI::Escape qw/uri_escape uri_unescape/;

# See Chisel::Builder::ZooKeeper::Base for ZooKeeper layout

sub new {
    my ( $class, %args ) = @_;
    $class->SUPER::new(
        zkh             => $args{'zkh'},
        connect         => $args{'connect'},
        session_timeout => 300000,

        # Are we the leader right now?
        is_leader => 0,

        # Members of the cluster?
        cluster => $args{'cluster'} || [],

        # Desired redundancy? (workers per built hostname)
        redundancy => $args{'redundancy'} || 1,

        # Deviation factor from ideal load before we try to shift out work?
        max_load_factor => $args{'max_load_factor'} || 1.2,
    );
}

# $nodemap: node -> bucket string
# this function attempts to balance nodes and bucket strings between the various
# workers in $self->{cluster}
# XXX - need to prune /h for hosts that are no longer part of the dataset
sub rebalance {
    my ( $self, $nodemap, %args ) = @_;

    # Only the current leader is allowed to update ZooKeeper partitions
    if( !$self->register( "leader" ) ) {
        LOGCONFESS "rebalance: Can only be called while we are the active leader";
    }

    my %work_by_worker;       # $work_by_worker{$worker}                = { hostname => bucketstr, ... }
    my %buckets_by_worker;    # $buckets_by_worker{$worker}{$bucketstr} = { hostname => 1, ... }
    my %workers_by_bucket;    # $workers_by_bucket{$bucketstr}          = [ worker1, worker2, ... ]
    my %workers_by_host;      # $workers_by_host{$host}{$worker}        = 1 if $worker has $host

    DEBUG "rebalance: Starting";

    # Initialize %buckets_by_worker (the next loop might not be able to)
    %buckets_by_worker = map { $_ => {} } @{ $self->{cluster} };

    # Load existing cluster partition... unless we're starting fresh
    if( !$args{'fresh'} ) {
        for my $worker ( sort @{ $self->{cluster} } ) {
            my $part = [ $self->get_part( $worker ) ];

            # Record work for $worker
            for my $host ( @$part ) {
                if( exists $nodemap->{$host} ) {
                    my $bucketstr = $nodemap->{$host};

                    $work_by_worker{$worker}{$host}                = $bucketstr;
                    $workers_by_host{$host}{$worker}               = 1;
                    $buckets_by_worker{$worker}{$bucketstr}{$host} = 1;

                    if( keys %{ $buckets_by_worker{$worker}{$bucketstr} } == 1 ) {
                        # First time we saw this $bucketstr for $worker
                        push @{ $workers_by_bucket{$bucketstr} }, $worker;
                    }
                }
            }
        }
    }

    # Function to register a host with a worker
    # $worker: worker id
    # $host: hostname
    my $register_host = sub {
        my ( $worker, $host ) = @_;

        if( $work_by_worker{$worker}{$host} ) {
            # Already registered.
            return;
        }

        my $bucketstr = $nodemap->{$host};

        DEBUG "rebalance: host [$host] on worker [$worker] assigned to bucket [$bucketstr]";

        # Update %work_by_worker with new bucketstr
        $work_by_worker{$worker}{$host} = $bucketstr;

        # Update %buckets_by_worker (add $host)
        $buckets_by_worker{$worker}{$bucketstr}{$host} = 1;

        # Update %workers_by_host (ensure $worker is present)
        $workers_by_host{$host}{$worker} = 1;

        # Update %workers_by_bucket (ensure $worker is present)
        push @{ $workers_by_bucket{$bucketstr} }, $worker
          if !any { $_ eq $worker } @{ $workers_by_bucket{$bucketstr} };
    };

    # Function to unregister a host from a worker
    # $worker: worker id
    # $host: hostname
    my $unregister_host = sub {
        my ( $worker, $host ) = @_;

        if( !$work_by_worker{$worker}{$host} ) {
            # Already unregistered.
            return;
        }

        my $bucketstr = $nodemap->{$host};

        DEBUG "rebalance: host [$host] on worker [$worker] removed";

        # Update %buckets_by_worker (remove $host)
        delete $buckets_by_worker{$worker}{$bucketstr}{$host};

        # Check if bucket is now gone from the $worker
        if( !keys %{ $buckets_by_worker{$worker}{$bucketstr} } ) {
            # This bucket is now gone from this worker
            DEBUG "rebalance: bucket [$bucketstr] is now gone from worker [$worker]";
            delete $buckets_by_worker{$worker}{$bucketstr};

            # Update %workers_by_bucket
            @{ $workers_by_bucket{$bucketstr} } =
              grep { $_ ne $worker } @{ $workers_by_bucket{$bucketstr} };

            # Check if bucket is gone completely
            if( !@{ $workers_by_bucket{$bucketstr} } ) {
                # This bucket is now gone completely
                DEBUG "rebalance: bucket [$bucketstr] is now gone completely";
                delete $workers_by_bucket{$bucketstr};
            }
        }

        # Update %work_by_worker and %workers_by_host
        delete $work_by_worker{$worker}{$host};
        delete $workers_by_host{$host}{$worker};

        # Check if host is gone completely
        if( !keys %{ $workers_by_host{$host} } ) {
            # This bucket is now gone completely
            DEBUG "rebalance: host [$host] is now gone completely";
            delete $workers_by_host{$host};
        }
    };

    # 1- Add hosts to workers if redundancy is too low
    for my $host ( keys %$nodemap ) {
        my $bucketstr = $nodemap->{$host};

        # Check redundancy
        # XXX this code is quite slow
        while( keys %{ $workers_by_host{$host} } < $self->{redundancy} ) {
            DEBUG "rebalance: host [$host] redundancy too low (" . ( scalar keys %{ $workers_by_host{$host} } ) . ")";

            my @worker_candidates = @{ $self->{cluster} };

            # Worker must not already have this host
            if( $workers_by_host{$host} ) {
                @worker_candidates = grep { !$workers_by_host{$host}{$_} } @worker_candidates;
            }

            # Prefer workers that already have this bucket
            my %worker_has_this_bucketstr = map { $_ => 1 } @{ $workers_by_bucket{$bucketstr} };
            if( any { $worker_has_this_bucketstr{$_} } @worker_candidates ) {
                @worker_candidates = grep { $worker_has_this_bucketstr{$_} } @worker_candidates;
            }

            # Prefer least loaded worker
            my ( $worker ) =
              sort { scalar keys %{ $buckets_by_worker{$a} } <=> scalar keys %{ $buckets_by_worker{$b} } }
              @worker_candidates;

            # If we can't find a worker, warn and continue
            if( !$worker ) {
                DEBUG "rebalance: cannot raise redundancy for host [$host] (out of workers)";
                last;
            }

            $register_host->( $worker, $host );
        }
    }

    # 2- Balance buckets between workers if load is too high
    my $ideal_load = int( ( scalar keys %workers_by_bucket ) * $self->{redundancy} / @{ $self->{cluster} } );
    my $max_load = int( $ideal_load * $self->{max_load_factor} );

    # XXX - Not sure what best target is
    # my $target_load = int( ( $ideal_load + $max_load ) / 2 );
    my $target_load = $ideal_load;

    for my $worker ( @{ $self->{cluster} } ) {
        my $load = scalar keys %{ $buckets_by_worker{$worker} };

        if( $load <= $max_load ) {
            DEBUG
              "rebalance: worker [$worker] load ok (ideal:$ideal_load target:$target_load max:$max_load current:$load)";
        } else {
            DEBUG
              "rebalance: worker [$worker] load too high (ideal:$ideal_load target:$target_load max:$max_load current:$load); trying to consolidate buckets";

            # Need to reduce load on $worker by shifting hosts to other workers

            # XXX - This method causes service interruptions. Need a feedback system based on advertising!

            # First do two things that never hurt:
            # - Try to merge bucket fragments (if another worker has the same bucket, send all our hosts there)
            # - Remove hosts that have too-high redundancy

            for my $host ( keys %{ $work_by_worker{$worker} } ) {
                my $bucketstr = $work_by_worker{$worker}{$host};

                if( keys %{ $workers_by_host{$host} } > $self->{redundancy} ) {
                    # This host has enough redundancy, just kill it
                    $unregister_host->( $worker, $host );
                } else {
                    # Can we merge this host into a bucket already being built somewhere else?
                    my ( $destination_worker ) =
                      grep { $_ ne $worker and !$workers_by_host{$host}{$_} } @{ $workers_by_bucket{$bucketstr} };

                    if( $destination_worker ) {
                        # This host can be merged into $destination_worker
                        $unregister_host->( $worker, $host );
                        $register_host->( $destination_worker, $host );
                    }
                }
            }

            # Recompute $load
            $load = scalar keys %{ $buckets_by_worker{$worker} };

            # We've exhausted the easy options.
            # If load is still too high we have to start shifting buckets instead of consolidating.

            # Move smallest buckets to least loaded workers
            # Smallest bucket: because it's faster to move smaller buckets
            # Least loaded target: because that makes sense

            my @buckets_by_size =
              sort { keys %{ $buckets_by_worker{$worker}{$a} } <=> keys %{ $buckets_by_worker{$worker}{$b} } }
              keys %{ $buckets_by_worker{$worker} };

          BUCKET: for my $bucketstr ( @buckets_by_size ) {
                last BUCKET if $load <= $target_load;

                DEBUG
                  "rebalance: worker [$worker] load too high (ideal:$ideal_load target:$target_load max:$max_load current:$load); trying to shift bucket [$bucketstr]";

                # Need to find another home for hosts belonging to $worker in $bucketstr
                # We're going to prefer the least loaded destination workers
                my @workers_by_load =
                  sort { keys %{ $buckets_by_worker{$a} } <=> keys %{ $buckets_by_worker{$b} } } @{ $self->{cluster} };

                for my $host ( keys %{ $buckets_by_worker{$worker}{$bucketstr} } ) {
                    # Find destination worker that does not already have $host
                    my ( $destination_worker ) = firstval { !$work_by_worker{$_}{$host} } @workers_by_load;

                    if( $destination_worker ) {
                        $unregister_host->( $worker, $host );
                        $register_host->( $destination_worker, $host );
                    } else {
                        # Can't find a destination worker, try a different bucket I guess.
                        DEBUG "rebalance: worker [$worker] cannot shift bucket [$bucketstr] due to host [$host]";
                        next BUCKET;
                    }
                }

                # We moved out all hosts in $bucketstr, so, adjust $load
                $load--;
            }
        }
    }

    # Last- update partitions in ZooKeeper

    for my $worker ( $self->_zk_get_children( "/w" ) ) {
        if( !$work_by_worker{$worker} ) {
            # Need to remove this partition
            DEBUG "rebalance: worker [$worker] is gone, removing partition";
            $self->update_part( worker => $worker, part => [] );
        }
    }

    for my $worker ( keys %work_by_worker ) {
        $self->update_part( worker => $worker, part => [ keys %{ $work_by_worker{$worker} } ] );
    }

    INFO "rebalance: Done";

    return 1;
}

# Update partition for one worker
sub update_part {
    my ( $self, %args ) = @_;

    my $worker = $args{'worker'};
    if( !$worker ) {
        LOGCONFESS "Missing 'worker'";
    }

    my $part = $args{'part'};
    if( !$part ) {
        LOGCONFESS "Missing 'part'";
    }

    # Only the current leader is allowed to update ZooKeeper partitions
    if( !$self->register( "leader" ) ) {
        LOGCONFESS "update_part: can only be called while we are the active leader";
    }

    # Special case- If part is empty, delete this partition
    if( !@$part ) {
        DEBUG "update_part: Removing /w/$worker";

        for my $d1 ( $self->_zk_get_children( "/w/$worker" ) ) {
            for my $d2 ( $self->_zk_get_children( "/w/$worker/$d1" ) ) {
                $self->_zk_delete( "/w/$worker/$d1/$d2" );
            }

            $self->_zk_delete( "/w/$worker/$d1" );
        }

        $self->_zk_delete( "/w/$worker" );

        return 1;
    }

    # Ensure work nodes exist for $worker

    DEBUG "update_part: $worker: Creating structure under /w/$worker (if needed)";

    $self->_zk_create( "/w/$worker", '', acl => ZOO_OPEN_ACL_UNSAFE );
    $self->_zk_create( "/w/$worker/" . lc sprintf( "%02X", $_ ), '', acl => ZOO_OPEN_ACL_UNSAFE ) for( 0 .. 255 );

    # Ensure advertisement container nodes exist for hosts in $part

    DEBUG "update_part: $worker: Creating nodes in /h (if needed)";

    my %advertisement_node_exists = map { $_ => 1 } $self->_zk_get_children( "/h" );

    for my $host ( @$part ) {
        # Create container node if it does not yet exist
        if( !$advertisement_node_exists{$host} ) {
            $self->_zk_create( "/h/$host", 'ok', acl => ZOO_OPEN_ACL_UNSAFE );
        }
    }

    # Load current partition for $worker
    DEBUG "update_part: $worker: Loading current partition";

    my $zpart = [ $self->get_part( $worker ) ];

    DEBUG "update_part: $worker: Cleaning up stale nodes from /w/$worker";

    # Clean up partition stored in zookeeper
    my %host_in_part  = map { $_ => 1 } @$part;
    my %host_in_zpart = map { $_ => 1 } @$zpart;

    for my $zhost ( @$zpart ) {
        if( !$host_in_part{$zhost} ) {
            # We don't want $zhost anymore.
            $self->_zk_delete( $self->_part_path( $worker, $zhost ) );
        }
    }

    DEBUG "update_part: $worker: Updating partition in /w/$worker";

    # Add to worker's partition in zk to match $part
    for my $host ( @$part ) {
        if( !$host_in_zpart{$host} ) {
            $self->_zk_create( $self->_part_path( $worker, $host ), '', acl => ZOO_OPEN_ACL_UNSAFE );
        }
    }

    DEBUG "update_part: $worker: Done updating partition";

    return 1;
}

sub _part_path {
    my ( $self, $worker, $host ) = @_;
    my $prefix = "/w/$worker/" . substr( Digest::MD5::md5_hex( $host ), 0, 2 ) . "/$host";
    return $prefix;
}

1;
