package ChiselTest::Overmind;

use strict;
use warnings;

use ChiselTest::Engine;
use Test::Differences;
use Test::Exception;
use Test::More;
use Scalar::Util;
use Chisel::Builder::Overmind;

use Exporter qw/import/;
our @EXPORT_OK = qw/ tco_overmind tco_smash0 blob_is blob_like blobsha_is nodelist_is nodefiles_are /;
our %EXPORT_TAGS = ( "all" => [@EXPORT_OK], );

my $OVERMIND;

# Singleton overmind
sub tco_overmind {
    if( !$OVERMIND ) {
        my $engine = ChiselTest::Engine->new;

        my $cp     = Chisel::CheckoutPack->new( filename => $engine->config( "var" ) . "/dropbox/checkout-p0.tar" );
        my $cpe    = $cp->extract;
        my $smash0 = tco_smash0();
        $cpe->smash( %$smash0 );
        $cp->write_from_fs( $cpe->stagedir );

        $engine->new_zookeeper_leader->config( 'pusher' => 'p0' );

        my $ov = $OVERMIND = ChiselTest::Overmind::Overmind2->new( engine_obj => $engine );
        Scalar::Util::weaken($OVERMIND);
        return $ov;
    } else {
        return $OVERMIND;
    }
}

# Initial value for checkoutpack tarball
sub tco_smash0 {
    my $engine     = ChiselTest::Engine->new;
    my $checkout   = $engine->new_checkout;
    my @transforms = $checkout->transforms;
    my $walrus     = $engine->new_walrus(
        no_add_host => 1,
        tags        => [],
        transforms  => \@transforms,
    );

    $walrus->add_host( host => $_ )
      for( 'bad0', 'bar1', 'barqux1', 'bin0', 'foo1', 'foo2', 'fooqux1', 'invalid1', 'mb0', 'u0' );
    my %host_transforms = map { $_ => [ $walrus->host_transforms( host => $_ ) ] } $walrus->range;
    return { raws => [ $checkout->raw ], host_transforms => \%host_transforms };
}

sub blob_is {
    my ( $host, $file, $contents ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $ws = Chisel::Workspace->new( dir => $OVERMIND->engine->config( 'var' ) . "/ws" );
    my $blob = $ws->host_file( $host, $file );

    if( !defined $contents ) {
        # expect no $blob found
        is( $blob, undef, "blob for $host/$file does not exist" );
    } else {
        # expect $contents
        is( $ws->cat_blob( $blob ), $contents, "blob contents for $host/$file" );
    }
}

sub blobsha_is {
    my ( $host, $file, $sha_expected ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $ws = Chisel::Workspace->new( dir => $OVERMIND->engine->config( 'var' ) . "/ws" );
    my $blob = $ws->host_file( $host, $file );
    is( $blob, $sha_expected, "blob sha for $host/$file" );
}

sub blob_like {
    my ( $host, $file, $contents_regex ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $ws = Chisel::Workspace->new( dir => $OVERMIND->engine->config( 'var' ) . "/ws" );
    my $blob = $ws->host_file( $host, $file );
    like( $ws->cat_blob( $blob ), $contents_regex, "blob $host/$file" );
}

sub nodelist_is {
    my ( $nodelist_expected ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $ws = Chisel::Workspace->new( dir => $OVERMIND->engine->config( 'var' ) . "/ws" );
    eq_or_diff( [ sort keys %{ $ws->nodemap } ], [ sort @$nodelist_expected ], "nodelist" );
}

sub nodefiles_are {
    my ( $hostname, $files_expected ) = @_;
    local $Test::Builder::Level = $Test::Builder::Level + 1;

    my $ws = Chisel::Workspace->new( dir => $OVERMIND->engine->config( 'var' ) . "/ws" );
    my $bucket = $ws->nodemap->{$hostname};
    eq_or_diff(
        [ $bucket ? sort keys %{ $bucket->manifest( emit => ['blob'], include_dotfiles => 1 ) } : () ],
        [ sort @$files_expected ],
        "files for $hostname"
    );
}

package ChiselTest::Overmind::Overmind2;

# Subclass of Overmind with *_exec overridden
use base 'Chisel::Builder::Overmind';

# Force pack_exec to die
our $OV_PACK_ERROR;

sub generate_exec {
    my ( $self, $args ) = @_;

    # 'raws' : replace hash with list of RawFile objects
    my $ws = Chisel::Workspace->new( dir => $OVERMIND->engine->config( 'var' ) . "/ws" );
    my @raws =
      map { Chisel::RawFile->new( name => $_, data => $ws->cat_blob( $args->{'raws'}{$_} ) ) }
      keys %{ $args->{'raws'} };

    my $ret = $self->engine->new_generator->generate( %$args, raws => \@raws );
    my $cv  = AnyEvent->condvar;
    $cv->send( $ret );
    return $cv;
}

sub pack_exec {
    my ( $self, $args ) = @_;

    my $ret =
      $OV_PACK_ERROR
      ? [ map +{ ok => 0, message => $OV_PACK_ERROR }, @{ $args->{'targets'} } ]
      : $self->engine->new_packer( sanity_socket => undef )->pack( %$args );
    my $cv = AnyEvent->condvar;
    $cv->send( $ret );
    return $cv;
}

sub run_once {
    my ( $self ) = @_;

    # Run through all stages
    $self->gc;
    $self->checkout->recv;
    $self->generate->recv;
    $self->pack->recv;
    $self->gc;

    return;
}

1;
