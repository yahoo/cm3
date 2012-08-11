######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Engine::Packer;

# inputs:  proto-buckets containing hostnames + generated files
# outputs: buckets with NODELIST, VERSION, REPO and sanity-checked and signed MANIFEST

use strict;

use Digest::MD5 qw/md5_hex/;
use Hash::Util ();
use Log::Log4perl qw/:easy/;
use YAML::XS ();

use Chisel::Bucket;
use Chisel::Integrity;
use Chisel::Transform;
use Chisel::Workspace;
use Regexp::Chisel qw/ :all /;

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # misc required stuff
        gnupghome     => '',       # location of our gnupg home directory, used for signing manifests
        sanity_socket => undef,    # socket to the sanity checker

        # outputs
        workspace => '',           # location of the workspace that we should update
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

        # object for interacting with the gnupg stuff in 'gnupghome'
        integrity_obj => Chisel::Integrity->new( gnupghome => $self->{gnupghome} ),

    );

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    Hash::Util::lock_value( %$self, $_ ) for keys %$self;
    return $self;
}

sub pack {
    my ( $self, %args ) = @_;

    # 'targets' is an arrayref of things like:
    # { hosts => [ hostname1, ... ], files => [ { name => "name1", blob => "blob1" }, ... ] }

    my @targets = @{ $args{'targets'} };

    # to save typing

    my $ws = $self->workspace;

    # text of VERSION, REPO (same for all buckets created this run)

    my $version_txt = $args{'version'} || 0;
    my $repo_txt    = $args{'repo'}    || "";
    $version_txt = "$version_txt\n" if $version_txt !~ /\n\z/;

    # blob sha and md5 of VERSION, REPO

    my $version_blob = $ws->store_blob( $version_txt );
    my $version_md5  = md5_hex( $version_txt );
    my $repo_blob    = $ws->store_blob( $repo_txt );
    my $repo_md5     = md5_hex( $repo_txt );

    # for storing whether we sent a blob to the sanity checker yet or not
    # (we only want to send each one once, for efficiency)

    my %sanity_got_blob;

    # Keep track of blob -> md5 association (for MANIFEST creation)

    my %blob_md5;

    # We will pack buckets, and push them into @result in the same order as @targets

    my @result;

  
    foreach my $target ( @targets ) {

        # List of hostnames

        my @hosts = @{ $target->{'hosts'} };

        # List of files

        my @files = @{ $target->{'files'} };

        # Bucket object

        my $bucket = Chisel::Bucket->new;

        # write regular files
        foreach my $file ( @files ) {
            $blob_md5{ $file->{'blob'} } ||= Digest::MD5::md5_hex( $ws->cat_blob( $file->{'blob'} ) );
            $bucket->add( file => $file->{'name'}, blob => $file->{'blob'}, md5 => $blob_md5{ $file->{'blob'} } );
        }

        # write special files
        # NODELIST - used for clients to make sure they got the right config
        # VERSION  - ditto
        # REPO     - just for fun

        my $nodelist_txt = join '', map { "$_\n" } sort @hosts;
        $bucket->add(
            file => 'NODELIST',
            blob => $ws->store_blob( $nodelist_txt ),
            md5  => md5_hex( $nodelist_txt ),
        );
        $bucket->add( file => 'VERSION', blob => $version_blob, md5 => $version_md5 );
        $bucket->add( file => 'REPO',    blob => $repo_blob,    md5 => $repo_md5 );

        # make MANIFEST
        my $m = $bucket->manifest_json( fake => [qw/ MANIFEST MANIFEST.asc /] );
        my $mblob = $ws->store_blob( $m );

        if( my $socket = $self->{sanity_socket} ) {
            # sanity protocol:
            # ==> we send a stream with two kinds of commands:
            #       ck 1234\n<content>\n
            #         ^ in this case we want it to return a signature for a 1234-byte MANIFEST
            #       bl 5678\n<content>\n
            #         ^ we're telling it that we are going to reference a 5678-byte blob with content <content>
            #           no acknowledgement is required or expected
            #
            # <== in response to 'ck' it sends us null-delimited records saying either:
            #       ok <ascii armored pgp signature of that MANIFEST>\0
            #         ^ in this case we add the sanity signature to MANIFEST.asc
            #       no <string error>\0
            #         ^ in this case we report the error and wipe the bucket

            # $self->metrics->start( 't_generate_sanity' );

            # get a list of all files in this bucket, so we can get them sent to the sanity checker as 'bl' lines
            my $mh = $bucket->manifest( skip => [qw/ MANIFEST MANIFEST.asc /], emit => [ 'blob', 'md5' ] );

            # send any that haven't been sent before, according to %sanity_got_blob
            foreach my $blob (
                grep { $_ && !$sanity_got_blob{$_} }
                map { $_->{blob} } sort { $a->{name} cmp $b->{name} } values %$mh
              )
            {
                # blob $blob needs sending
                my $blob_contents = $ws->cat_blob( $blob );
                my $blob_length   = length( $blob_contents );
                print $socket "bl $blob_length\n$blob_contents\n";

                # don't send it again
                $sanity_got_blob{$blob} = 1;
            }

            # request a check of our manifest
            print $socket "ck " . length( $m ) . "\n$m\n";

            # let the sanity checker do its thing while we continue...
        }

        # sign MANIFEST (or don't)
        my $ms =
            $self->{gnupghome}
          ? $self->integrity->sign( contents => $m, key => "chiselbuilder" )
          : '';

        # now see if the sanity-checker has anything for us
        if( my $socket = $self->{sanity_socket} ) {
            # get the response back from the sanity-checker
            my $sr;
            do {
                local $/ = "\0";
                chomp( $sr = <$socket> );
            };

            # it could either be 'ok', 'no', or a malformed response
            if( $sr =~ /^ok (-----BEGIN PGP SIGNATURE-----\n[\w\d:\-\+\=\/\(\)\.\s]+-----END PGP SIGNATURE-----\n)$/s )
            {
                # append this to MANIFEST.asc ($ms)
                $ms .= "$1\n";
            } elsif( $sr =~ /^no (.*)$/s ) {
                # record this error and skip to the next bucket
                push @result, { ok => 0, message => "Sanity check failed!\n$1" };
                next;
            } else {
                # something's wrong with the sanity checker, let's actually die
                LOGCONFESS "Something's wrong with the sanity checker! Got:\n$sr";
            }
        }

        # write MANIFEST signature to the object database
        my $msblob = $ws->store_blob( $ms );

        # add MANIFEST + signature to bucket
        $bucket->add( file => "MANIFEST",     blob => $mblob );
        $bucket->add( file => "MANIFEST.asc", blob => $msblob );

        # write the bucket to the object database
        $ws->store_bucket( $bucket );

        # return this bucket and mark it OK
        push @result, { ok => 1, bucket => $bucket->tree };

        # write a log message to show we're done
        DEBUG "Stored bucket: $bucket";

    }

    return \@result;
}

# sub metrics    { return shift->{metrics_obj} }
# sub scoreboard { return shift->{scoreboard_obj} }

sub integrity { return shift->{integrity_obj} }
sub workspace { return shift->{workspace_obj} }

1;
