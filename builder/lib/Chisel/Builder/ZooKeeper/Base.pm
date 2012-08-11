######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::ZooKeeper::Base;

use strict;

use Digest::MD5 ();
use JSON::XS;
use List::MoreUtils qw/any/;
use Log::Log4perl qw/:easy/;
use Net::ZooKeeper qw/:node_flags :errors :acls/;

use Regexp::Chisel qw/:all/;

sub new {
    my ( $class, %args ) = @_;

    my $zk;

    if( !$args{'zkh'} ) {
        # ZooKeeper connection string (like "localhost:2181")
        my $connect = delete $args{'connect'};

        # ZooKeeper session timeout (we'll use the default if missing)
        my $session_timeout = delete $args{'session_timeout'};

        if( !$connect ) {
            LOGCROAK "Need a ZooKeeper 'connect' string";
        }

        # Connect to ZooKeeper
        $zk = Net::ZooKeeper->new( $connect, session_timeout => $session_timeout );

        # Increase data_read_len to maximum znode size (1M)
        $zk->{'data_read_len'} = 1 << 20;

        # Increase path_read_len as well. Not sure what the max is so use the same 1M
        $zk->{'path_read_len'} = 1 << 20;
    } else {
        $zk = $args{'zkh'};
    }

    # Here's the object
    my $self = {
        # ZooKeeper handle
        zk => $zk,

        # Claimed keys in /r
        r => [],

        # any other args passed by caller
        %args,
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );

    # Ensure zookeeper structure is set up
    $self->setup_structure;

    # Print informational message
    # Note that this is only valid after "setup_structure"
    # because the connect to ZK does not happen until a command is issued
    INFO "Connected to ZooKeeper with session id [" . $self->_zk_session_id . "] timeout [$zk->{session_timeout}]";

    return $self;
}

# Set up our ZooKeeper structure, which needs to support this:
#   /r/key               ->   znode created by some session to claim some key exclusively
#   /c/key               ->   cluster-wide configuration key
#   /w/b0/e3/foo-bucket  ->   empty znode created by leader meaning "b0, please build 'foo' with bucket 'bucket'"
#   /b/bucket            ->   json file created by leader with transforms for bucket "bucket"
#   /h/foo/b0            ->   ephemeral znode created by builder b0 saying "we can serve host foo"
#   /hr/foo              ->   most recent report json for host "foo"
sub setup_structure {
    my ( $self ) = @_;

    my $zk = $self->_zk;

    foreach my $znode ( qw!/r /w /h /c /hr! ) {
        $zk->create( $znode, '', acl => ZOO_OPEN_ACL_UNSAFE );
        if( $zk->get_error() != ZOK && $zk->get_error() != ZNODEEXISTS ) {
            LOGCONFESS "unable to create znode [$znode]: " . $zk->get_error . "\n";
        }
    }

    1;
}

# Attempt to claim a key in /r
# Once a key is claimed, it will remain claimed for the entire session (it won't be given up)
# Returns true if claimed, false if not
sub register {
    my ( $self, $key ) = @_;

    if( any { $_ eq $key } @{ $self->{r} } ) {
        # Because we do not reconnect to ZooKeeper, and nobody
        # will forcibly delete a claimed key, we know that once
        # this flag is set we have a valid claim.
        return $self->_zk_session_id;
    }

    # We're not currently registered, try to do it.
    $self->_zk_create(
        "/r/$key", $self->_zk_session_id,
        flags => ZOO_EPHEMERAL,
        acl   => ZOO_OPEN_ACL_UNSAFE
    );

    if( $self->registered( $key ) eq $self->_zk_session_id ) {
        push @{ $self->{r} }, $key;
        return $self->_zk_session_id;
    } else {
        return;
    }
}

# Get or set a configuration key in /c
sub config {
    my ( $self, $key, $value ) = @_;

    if( !defined $value ) {
        # Read the key
        return $self->_zk_get( "/c/$key" );
    } else {
        # Set the key
        $self->_zk_create( "/c/$key", $value, acl => ZOO_OPEN_ACL_UNSAFE );
        $self->_zk_set( "/c/$key", $value );
        return $value;
    }
}

# Check who has claimed a key in /r
# Returns ZK session id, or undef if nobody has the claim
sub registered {
    my ( $self, $key ) = @_;

    if( my $session = $self->_zk_get( "/r/$key" ) ) {
        return $session;
    } else {
        return;
    }
}

# Get list of workers
sub get_workers {
    my ( $self ) = @_;
    return $self->_zk_get_children( "/w" );
}

# Get partition for a particular worker
# (The list of hostnames it is supposed to build for)
sub get_part {
    my ( $self, $worker ) = @_;

    if( !defined $worker ) {
        $worker = $self->{worker};
    }

    DEBUG "Start loading partition for worker [$worker]";

    my @zwork;

    for my $n ( 0 .. 255 ) {
        push @zwork, $self->_zk_get_children( "/w/$worker/" . lc sprintf( "%02X", $n ) );
    }

    DEBUG "Done loading partition for worker [$worker] with " . ( scalar @zwork ) . " entries";

    return @zwork;
}

# List all workers with partitions containing a particular host
sub get_assignments_for_host {
    my ( $self, $host ) = @_;

    my @ads;
    my @workers = $self->get_workers;
    my $suffix = substr( Digest::MD5::md5_hex( $host ), 0, 2 ) . "/$host";
    for my $worker ( @workers ) {
        if( defined $self->_zk_get( "/w/$worker/$suffix" ) ) {
            push @ads, $worker;
        }
    }

    return @ads;
}

# List all workers advertising a particular host
sub get_workers_for_host {
    my ( $self, $host ) = @_;
    return $self->_zk_get_children( "/h/$host" );
}

# Find the primary worker for a particular host (by checking advertisements)
sub get_worker_for_host {
    my ( $self, $host ) = @_;

    my @ret = sort $self->get_workers_for_host( $host );

    if( @ret ) {
        # Pick the same one every time for consistency
        my ( $md5_first_byte ) = hex( unpack( "H2", Digest::MD5::md5( $host ) ) );
        my $worker = $ret[ $md5_first_byte % scalar @ret ];
        return $worker;
    } else {
        # No worker can serve this host
        return;
    }
}

# wrapper around Net::ZooKeeper->create with die-on-error
sub _zk_create {
    my ( $self, @args ) = @_;

    my $zk  = $self->_zk;
    my $ret = $zk->create( @args );
    if( !$ret && $zk->get_error() != ZNODEEXISTS ) {
        LOGCONFESS "unable to create znode \[$args[0]\]: " . $zk->get_error . "\n";
    }

    return $ret;
}

# wrapper around Net::ZooKeeper->get_children with die-on-error
# but in case of ZNONODE, just return empty list
sub _zk_get_children {
    my ( $self, @args ) = @_;

    my $zk  = $self->_zk;
    my @ret = $zk->get_children( @args );
    if( $zk->get_error() == ZNONODE ) {
        # node doesn't exist
        # pretend there are no children
        @ret = ();
    } elsif( $zk->get_error() != ZOK ) {
        LOGCONFESS "unable to get children of znode \[$args[0]\]: " . $zk->get_error . "\n";
    }

    return @ret;
}

# wrapper around Net::ZooKeeper->get_children with die-on-error
# but in case of ZNONODE, just continue
sub _zk_delete {
    my ( $self, @args ) = @_;

    my $zk  = $self->_zk;
    my $ret = $zk->delete( @args );

    if( !$ret && $zk->get_error() != ZNONODE ) {
        LOGCONFESS "unable to delete znode \[$args[0]\]: " . $zk->get_error . "\n";
    }

    return $ret;
}

# wrapper around Net::ZooKeeper->get with die-on-error
# but in case of ZNONODE, just return undef
sub _zk_get {
    my ( $self, @args ) = @_;

    my $zk  = $self->_zk;
    my $ret = $zk->get( @args );

    if( !defined $ret && $zk->get_error() != ZNONODE ) {
        LOGCONFESS "unable to get znode \[$args[0]\]: " . $zk->get_error . "\n";
    }

    return $ret;
}

sub _zk_set {
    my ( $self, @args ) = @_;

    my $zk  = $self->_zk;
    my $ret = $zk->set( @args );

    if( !$ret ) {
        LOGCONFESS "unable to set znode \[$args[0]\]: " . $zk->get_error . "\n";
    }

    return $ret;
}

sub _zk_exists {
    my ( $self, @args ) = @_;

    my $zk  = $self->_zk;
    my $ret = $zk->exists( @args );

    if( $zk->get_error() != ZNONODE && $zk->get_error() != ZOK ) {
        LOGCONFESS "unable to check znode \[$args[0]\]: " . $zk->get_error . "\n";
    }

    return $ret;
}

sub _zk_session_id {
    my ( $self ) = @_;
    return unpack( "H*", $self->_zk->{session_id} );
}

sub _zk {
    my ( $self ) = @_;
    return $self->{'zk'};
}

1;
