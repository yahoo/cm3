######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Engine::Generator;

# inputs:  desired generation targets (filename + transforms + raw files)
# outputs: generated targets

use strict;

use Carp;
use Digest::MD5   ( 'md5_hex' );
use Encode        ();
use Hash::Util    ();
use JSON::XS      ();
use Log::Log4perl ( ':easy' );

use Chisel::Transform;
use Chisel::Workspace;
use Regexp::Chisel ( ':all' );

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        workspace => '',    # location of the workspace that we should update
    };

    my $self = { %$defaults, %rest };

    if( keys %$self > keys %$defaults ) {
        LOGDIE "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    # add internals
    %$self = (
        %$self,

        # object for interacting with the repo in 'workspace'
        workspace_obj => Chisel::Workspace->new( dir => $self->{workspace} ),

    );

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

# %args: hash like
#     {
#         raw: [ obj1, obj2, ... ],
#         targets: [
#             { transforms => [ obj1, obj2, ... ], file => "files/motd/MAIN" },
#         ]
#     }
# return: array that matches "targets" from input (index by index), like
#     [
#         { ok => 1, blob => "blob sha" },
#         { ok => 0, message => "error msg"},
#     ]
sub generate {
    my ( $self, %args ) = @_;

    # 'targets' is an arrayref of things like:
    # { transforms => [ ... ], file => "files/motd/MAIN" }

    my @targets = @{ $args{'targets'} };

    # 'raws' is an arrayref of RawFile objects:
    # [ rf1, rf2, ... ]

    my @raws = @{ $args{'raws'} };

    # Create transform context out of @raws

    my $transform_ctx = Chisel::Builder::Engine::Generator::Context->new( raws => \@raws );

    # We will generate files, and push them into @result in the same order as @targets

    my @result;

    foreach my $target ( @targets ) {

        # XXX TRACE "Target [$target->{key}] start";

        my $contents;
        my $r = eval {
            $contents = $self->construct(
                file       => $target->{'file'},
                transforms => $target->{'transforms'},
                ctx        => $transform_ctx,
                );

            1;
        };

        # stop stopwatch, record only if successful
        my $t_gen_target = ymonsb_sw_stop($sw_gen_target);

        if( defined $r ) {
            # success. $contents might be undef, that's ok (it means don't include the file)
            # XXX TRACE "Target [$target->{key}] done OK";
       
            my $blob = defined $contents ? $self->{'workspace_obj'}->store_blob( $contents ) : undef;

            push @result, { ok => 1, blob => $blob, };
        } else {
            # failure
            chomp( my $err = $@ );
            # XXX TRACE "Target [$target->{key}] done FAILED [$err]";

            push @result, { ok => 0, message => $err, };
        }
    }

    # write out time to build all of @targets
    my $t_generate = ymonsb_sw_stop($sw_generate);
  
    return \@result;
}

# make 'file' from 'transforms'
# returns generated contents
# returns undef if the blob shouldn't exist for this 'file' / 'transforms' pair (usually due to unlink)
# dies on error
sub construct {
    my ( $self, %args ) = @_;

    defined( $args{$_} ) or confess( "$_ not given" ) for qw/ file transforms ctx /;

    # XXX rawdir hack hack hack
    if( $args{file} =~ m{^scripts/([^/]+(?<!\.asc))(?:\.asc|)$} ) {
        # a script, chroot into its modules/blah/scripts directory
        $args{ctx}->cd( "/modules/$1" );
    } elsif( $args{file} =~ m{^files/} ) {
        # a regular file, use the raw filesystem as-is
        $args{ctx}->cd( "" );
    } else {
        confess "$args{file}: bad path";
    }

    DEBUG "Constructing file [$args{file}] from transforms ["
      . join( ', ', map { $_->id } @{ $args{'transforms'} } ) . "]";

    my $transform_model;

    foreach my $t ( @{ $args{transforms} } ) {
        next if !$t->does_transform( file => $args{file} );

        # create $transform_model if it doesn't exist yet
        if( !$transform_model ) {
            my $transform_model_class = $t->model( file => $args{file} );
            $transform_model = $transform_model_class->new( ctx => $args{ctx} );
        }

        my $ret = $t->transform( file => $args{file}, model => $transform_model );

        # return 1 => keep going
        # return 0 => stop and remove file
        # undef => error

        if( !defined $ret ) {
            # fail if the transform thought something went wrong
            confess( "Transforming $t for " . $args{file} . " failed" );
        } elsif( $ret == 0 ) {
            return undef;
        } elsif( $ret != 1 ) {
            # this transform is buggy
            confess( "Transform $t for " . $args{file} . " returned nonsense" );
        }
    }

    my $contents = $transform_model->text;

    # convert to bytes if this is a character string
    if( utf8::is_utf8( $contents ) ) {
        $contents = Encode::encode_utf8( $contents );
    }

    # return contents
    return $contents;
}

sub workspace { shift->{workspace_obj} }

package Chisel::Builder::Engine::Generator::Context;

use strict;

use Carp;
use Hash::Util ();
use Log::Log4perl ( ':easy' );

# Chisel::TransformModel classes (transform action implementations) needs a $ctx
# argument that can provide it raw files. This is that context.

sub new {
    my ( $class, %rest ) = @_;

    my $self = {
        # hacky thing that stores usernames => passwd lines
        map => undef,

        # hash for looking up raw files
        # XXX changed to case insensitive for now -- possibly forever, but would like it to become sensitive again
        raw_lookup => { map { lc $_->name => $_->decode } @{ $rest{raws} } },

        # XXX hacky thing for prepending a "working directory" onto ->readraw calls
        raw_chdir => "",
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

sub cd {
    my ( $self, $newchdir ) = @_;
    $self->{raw_chdir} = $newchdir;
}

sub readraw {
    my ( $self, %args ) = @_;

    if( defined $args{file} ) {
        # add raw_chdir and strip slashes (we end up allowing leading slashes, unlike Raw)
        # XXX changed to case insensitive for now -- possibly forever, but would like it to become sensitive again
        my $key = lc "$self->{raw_chdir}/$args{file}";
        $key =~ s{^/+}{};

        if( defined $self->{raw_lookup}{$key} ) {
            return $self->{raw_lookup}{$key};
        } else {
            LOGDIE "file does not exist: $key";
        }
    } else {
        LOGDIE "file not given\n";
    }
}

1;
