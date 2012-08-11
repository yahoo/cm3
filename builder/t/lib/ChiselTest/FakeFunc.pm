package ChiselTest::FakeFunc;

use strict;
use warnings;
use YAML::XS;

sub new {
    my ( $class, $yaml ) = @_;

    my $range = YAML::XS::LoadFile( $yaml );
    bless {
        err   => undef,
        range => $range,
        ret   => undef,
    }, $class;
}

sub impl {
    qw/ func cmdb_property /;
}

sub fetch {
    my ( $self, %args ) = @_;

    my $nodes  = $args{hosts};
    my $groups = $args{groups};

    # allow override of callback value, for convenient testing of how Group.pm handles certain things
    if( defined $self->{ret} ) {
        $args{cb}->( @{ $self->{ret} } );
    } else {
        foreach my $group ( @$groups ) {
            $args{cb}->( $_, $group ) for $self->func( $group );
        }
    }

    return;
}

sub func {
    my ( $self, $range ) = @_;

    $range =~ s{^func/}{};
    $range =~ s{^(cmdb_property/.+)}{lc $1}e;

    if( exists $self->{range}{$range} ) {
        return @{ $self->{range}{$range} };
    } else {
        die "fake range $range doesn't exist";
    }
}

1;
