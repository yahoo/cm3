# Mock of Net::ZooKeeper

package ChiselTest::Mock::ZooKeeper;

use strict;
use Carp qw/confess/;
use Hash::Util ();
use Net::ZooKeeper qw/:errors/;

my $NEXT_SESSION = 1;

sub new {
    # ignore constructor parameters
    my ( $class, %args ) = @_;
    my $self = {
        data_read_len   => 0,
        path_read_len   => 0,
        znode           => $args{'share'} ? $args{'share'}{'znode'} : {},
        error           => ZOK,
        session_id      => pack("C", $NEXT_SESSION++),
        session_timeout => 1000,
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

sub get_error {
    my ( $self ) = @_;
    return $self->{error};
}

sub create {
    my ( $self, $k, $v ) = @_;
    if( ! defined $v ) {
        confess "no value";
    }
    if( exists $self->{znode}{$k} ) {
        $self->{error} = ZNODEEXISTS;
        return undef;
    } else {
        $self->{error} = ZOK;
        $self->{znode}{$k} = $v;
        return $k;
    }
}

sub get_children {
    my ( $self, $k ) = @_;
    if( exists $self->{znode}{$k} ) {
        $self->{error} = ZOK;
        my @children;
        for my $z (keys %{$self->{znode}}) {
            if( $z =~ m!^\Q$k\E/([^/]+)$! ) {
                push @children, $1;
            }
        }
        return @children;
    } else {
        $self->{error} = ZNONODE;
        return;
    }
}

sub delete {
    my ( $self, $k ) = @_;
    if( exists $self->{znode}{$k} ) {
        if( grep { m!^\Q$k\E/! } keys %{ $self->{znode} } ) {
            $self->{error} = ZNOTEMPTY;
            return;
        } else {
            $self->{error} = ZOK;
            delete $self->{znode}{$k};
            return 1;
        }
    } else {
        $self->{error} = ZNONODE;
        return;
    }
}

sub exists {
    my ( $self, $k ) = @_;
    if( exists $self->{znode}{$k} ) {
        $self->{error} = ZOK;
        return 1;
    } else {
        $self->{error} = ZNONODE;
        return undef;
    }
}

sub get {
    my ( $self, $k ) = @_;
    if( exists $self->{znode}{$k} ) {
        $self->{error} = ZOK;
        return $self->{znode}{$k};
    } else {
        $self->{error} = ZNONODE;
        return;
    }
}

sub set {
    my ( $self, $k, $v ) = @_;
    if( exists $self->{znode}{$k} ) {
        $self->{error} = ZOK;
        $self->{znode}{$k} = $v;
        return 1;
    } else {
        $self->{error} = ZNONODE;
        return;
    }
}

1;
