package ChiselTest::Transform;

use strict;
use warnings;
use Test::More;
use Chisel::Transform;

use Exporter qw/import/;
our @EXPORT_OK = qw/ transform_test tyaml /;
our %EXPORT_TAGS = ( "all" => [@EXPORT_OK], );

# run a transform on "/files/motd/MAIN"
sub transform_test(@) {
    my %args = @_;

    # label for this test (its name)
    my $label = $args{'name'} || 'untitled transform_test';

    # expected return code (default is 1, unless 'throws' is set in which case default is 'undef')
    # we must use 'exists' because we accept 'undef' as an expectation
    my $ret = exists $args{'ret'} ? $args{'ret'} : $args{'throws'} ? undef : 1;

    # expected exception (default is no exception)
    my $err = exists $args{'throws'} ? $args{'throws'} : qr/^$/;

    # transform model to use for this test
    my $model_shortclass = $args{'model'} || 'Text';

    # instantiate the transform
    my $t = Chisel::Transform->new(
        name        => 'dummy/dummy',
        yaml        => $args{'yaml'},
        module_conf => { motd => { model => { 'MAIN' => $model_shortclass } } },
    );

    # make a context for this transform (used for reading raw files, and caching stuff)
    my $ctx = bless {}, 'FakeTransformCtx';

    subtest $label => sub {
        plan tests => 3;

        # we need to run this test twice: once with the global context and once with our private context
        # just to make sure nothing weird is going on with the contexts

        # create model for this test
        my $model_class = 'Chisel::TransformModel::' . $model_shortclass;
        eval "require $model_class;" or die $@;
        my $model = $model_class->new( contents => $args{'from'}, ctx => $ctx );

        # run both tests
        my $ret_got = eval { $t->transform( file => 'files/motd/MAIN', model => $model ) };
        my $err_got = $@;

        # now check against the desired return parameters
        is( $ret_got, $ret, "$label: return value" );
        like( $err_got, $err, "$label: \$\@ value" );

        # we only care about the 'to' value if $ret is set (on failures, it doesn't matter what happens)
        if( $ret ) {
            is( $model->text, $args{'to'}, "$label: transformed file" );
        } else {
            # dummy test
            pass();
        }
    };
}

# helper for making transform yamls
sub tyaml {
    my @lines = @_;

    my $lines_joined = YAML::XS::Dump(\@lines);
    $lines_joined =~ s/^---//;
    return <<EOT;
# comments are fun
motd:
$lines_joined

# extra stuff, just in case
motd/x:
- append DUMMY

whatever:
- append DUMMY

---
# metadata section
follows:
- yourmom
EOT
}

package FakeTransformCtx;

sub readraw {
    my ( $self, %args ) = @_;

    my %rawfile = (
        # normal rawfiles
        'rawtest'   => "line one\nline two\n",
        'rawtest2'  => "line three\n",
        'someusers' => "bob\ncarol\n",

        # passwd is exposed as a pseudo-rawfile
        'passwd'   => "sshd:x:75:q\nbob:a:10000:b\ncarol:r:20000:s\ndave:x:30000:y\nnobody7:x:4294967294:z\n",

        'group' => <<'EOT',
# a comment!
wheel:*:0:root,bob
daemon:*:1:daemon
kmem:*:2:root
sys:*:3:root
tty:*:4:root
operator:*:5:root,bob
answersued:*:5554:carol
1mc-ops:*:5555:dave
worlds:*:60004:
Apex_DS:*:60005:
uus_udb_buddylist:*:755685:eddie
EOT

        # invokefor groups are implemented as pseudo-rawfiles
        'func/bbb01-03'      => "bbb01\nbbb02\nbbb03\n",
        'func/empty()'       => "",
        'func/>\'a(b) & c"'  => "abc\ndef\n",

        # dns names we might want
        'dns/foo.fake-domain.com' => "10.0.0.1\n",
        'dns/bar.fake-domain.com' => "\n", # unresolvable name
        'dns/baz.fake-domain.com' => "10.0.0.3\n",
        'dns/role:foo.bar'  => "10.1.0.1\n10.1.0.2\n",
        'dns/role:foo.baz'  => "", # empty role
        'dns/role:foo.qux'  => "10.1.0.1\n\n10.1.0.2\n", # role with one unresolvable name
    );

    defined $args{'file'} && exists $rawfile{$args{'file'}} ? $rawfile{$args{'file'}} : Carp::confess( "range error" );
};

1;
