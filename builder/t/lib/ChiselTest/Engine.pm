package ChiselTest::Engine;

use strict;
use warnings;

use base 'Chisel::Builder::Engine';

use ChiselTest::FakeFunc;
use ChiselTest::Mock::ZooKeeper;
use File::Temp qw/tempdir/;

our $CLEANUP = defined $ENV{'CHISEL_CLEANUP'} ? $ENV{'CHISEL_CLEANUP'} : 1;

sub new {
    my ( $class, %args ) = @_;
    my $tmp = tempdir( DIR => '.', CLEANUP => $CLEANUP );

    # set up skeleton
    mkdir "$tmp/dropbox";
    mkdir "$tmp/status";

    # set up a tmp workspace
    system( "cd $tmp && mkdir ws" );

    # fill gnupghome
    mkdir "$tmp/gnupghome";
    chmod 0700, "$tmp/gnupghome";
    system
      "gpg --homedir $tmp/gnupghome --import ../integrity/t/files/keyrings/autoring.asc ../integrity/t/files/keyrings/autoring-sec.asc 2>&1 >/dev/null";
    system "cp $tmp/gnupghome/pubring.gpg $tmp/gnupghome/trustedkeys.gpg";

    # copy configs.1 directory
    mkdir "$tmp/indir";
    system "cp -R t/files/configs.1/raw $tmp/indir/raw";
    system "cp -R t/files/configs.1/tags $tmp/indir/tags";
    system "cp -R t/files/configs.1/transforms $tmp/indir/transforms";
    system "cp -R t/files/configs.1/modules $tmp/modules";

    # figure out the appropriate log level
    my $l4plevel = $ENV{VERBOSE} ? 'TRACE' : 'OFF';

    # copy builder.conf, change ::TMP:: to $tmp, put in the right log level
    system "cp t/files/builder.conf $tmp/builder.conf";
    system "perl -pi -e's!::TMP::!$tmp!g' $tmp/builder.conf";
    system "perl -pi -e's!::L4PLEVEL::!$l4plevel!g' $tmp/builder.conf";

    my $self = $class->SUPER::new(
        configfile => "$tmp/builder.conf",
        mdbm_file  => "$tmp/metrics.mdbm",
        zkh        => ChiselTest::Mock::ZooKeeper->new,
    );
    $self->setup;

    # read config file, set up log4perl, and return
    $self->setup;
    return $self;
}

sub new_packer {
    my ( $self, %args ) = @_;
    return $self->SUPER::new_packer( sanity_socket => undef, %args );
}

sub new_walrus {
    my ( $self, %args ) = @_;

    my $no_add_host = delete $args{'no_add_host'};

    my $g      = Chisel::Builder::Group->new;
    my $g_host = Chisel::Builder::Group::Host->new;
    my $g_ffnc = ChiselTest::FakeFunc->new( "t/files/ranges.yaml" );
    $g->register( plugin => $g_host );
    $g->register( plugin => $g_ffnc );

    my $walrus = $self->SUPER::new_walrus(
        groupobj      => $g,
        require_group => undef,
        %args,
    );

    unless( $no_add_host ) {
        my $all = YAML::XS::LoadFile( "t/files/ranges.yaml" )->{ALL};
        $walrus->add_host( host => $_ ) for @$all;
    }

    return $walrus;
}

# return handle to ZooKeeper leader object
sub new_zookeeper_leader {
    my ( $self ) = @_;
    return Chisel::Builder::ZooKeeper::Leader->new( zkh => $self->config( "zkh" ), );
}

# return handle to ZooKeeper worker object
# there is only ONE of these
sub new_zookeeper_worker {
    my ( $self, $worker ) = @_;
    $worker ||= 'worker0';
    return Chisel::Builder::ZooKeeper::Worker->new( zkh => $self->config( "zkh" ), worker => $worker );
}

1;
