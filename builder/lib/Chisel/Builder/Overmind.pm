######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Overmind;

use strict;
use 5.010;

use AnyEvent::Util ();
use AnyEvent;
use Digest::MD5     ();
use File::Temp      ();
use Hash::Util      ();
use JSON::XS        ();
use List::MoreUtils ( 'any' );
use Log::Log4perl   ( ':easy' );
use POSIX           ( 'ceil' );
use Scalar::Util    ();
use Storable        ();
use Time::HiRes     ( 'gettimeofday', 'tv_interval' );
use YAML::XS        ();

use Chisel::Builder::Engine;
use Chisel::Builder::Overmind::Host;
use Chisel::Builder::Overmind::Metafile;
use Chisel::Builder::Overmind::TransformSet;
use Chisel::CheckoutPack;

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # state that is init'ed once and doesn't change
        engine_obj    => undef,
        workspace_obj => undef,

        # checkout tarball path
        checkout_tar => undef,

        # checkout tarball most recent stat mtime
        checkout_mtime => undef,

        # checkout tarball version number
        checkout_version => undef,

        # module_conf we're going to pass to all new Transform objects
        module_conf => undef,

        # index of hostname -> host object
        hosts => undef,

        # index of metafile id -> list of transformset object
        metafile_transformset => undef,

        # index of transform id -> useful information about it
        transforms => undef,

        # index of transform set id -> transform set object
        # ensures we only have one instance of each
        transformsets => undef,

        # index of metafile id -> metafile object
        # ensures we only have one instance of each
        metafiles => undef,

        # index of raw file name -> rawfile blob
        # only contains entries for which "data" is defined -- no placeholders
        raws => undef,

        # do we want to do a workspace garbage collection?
        # we need to stop everything while it is ongoing.
        need_gc => undef,

        # walrus condvar (anyevent)
        walrus_cv => undef,

        # generate condvar (anyevent)
        generate_cv => undef,

        # pack condvar (anyevent)
        pack_cv => undef,
    };

    my $self = { %$defaults, %rest };
    if( keys %$self > keys %$defaults ) {
        LOGDIE "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    if( !defined $self->{engine_obj} ) {
        LOGCROAK "Please pass in an 'engine_obj'";
    }

    if( !defined $self->{workspace_obj} ) {
        $self->{workspace_obj} = Chisel::Workspace->new( dir => $self->{engine_obj}->config( 'var' ) . "/ws" );
    }

    if( !defined $self->{module_conf} ) {
        # We're going to set this once instead of re-reading it continuously
        # This will help prevent things from getting weird if different transform objects have
        # different versions of module_conf
        my $checkout = $self->{engine_obj}->new_checkout;
        my %module_conf = map { $_ => $checkout->module( name => $_ ) } $checkout->modules;
        $self->{module_conf} = \%module_conf;
    }

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

# XXX split into more subroutines
sub run {
    my ( $self ) = @_;

    # First -- load previous nodemap into $self->{hosts}. We will change it if necessary.
    # XXX we basically bump all the VERSIONs soon after loading this, since we have no
    # XXX way of detecting that the contents have not changed. that is lame.

    my $nodemap = $self->workspace->nodemap( no_object => 1 );
    while( my ( $hostname, $bucket ) = each %$nodemap ) {
        $self->host( $hostname );
    }

    # CHECKOUT GRAB

    my $checkout_timer = $self->timer(
        name     => 'checkout',
        after    => 0,
        interval => 30,
        cb       => sub { $self->checkout; },
    );

    # GENERATE

    my $generate_timer = $self->timer(
        name     => 'generate',
        after    => 0,
        interval => 5,
        cb       => sub { $self->generate; },
    );

    # PACK

    my $pack_timer = $self->timer(
        name     => 'pack',
        after    => 0,
        interval => 5,
        cb       => sub { $self->pack; },
    );

    # DEBUG

    # my $debug_timer = $self->timer(
    #     name     => 'debug',
    #     after    => 30,
    #     interval => 60,
    #     cb       => sub { YAML::XS::DumpFile( '/tmp/woo', $self ) },
    # );

    # GARBAGE COLLECTION

    my $need_gc_timer = $self->timer(
        name     => 'gc',
        after    => 60,
        interval => $self->engine->config("gc_interval") || 600,
        cb       => sub { $self->{'need_gc'} = 1; },
    );

    my $do_gc_timer = $self->timer(
        name     => 'do_gc',
        after    => 5,
        interval => 5,
        cb       => sub {
            if( $self->{'need_gc'} && !defined $self->{'generate_cv'} && !defined $self->{'pack_cv'} ) {
                $self->gc;
                undef $self->{'need_gc'};
            }
        },
    );

    # XXX Useful when we need to run under a profiler
    # XXX But I'm not sure if it's a good idea generally (might cause issues with restarts)
    # my $sigterm_watcher = AnyEvent->signal( signal => "TERM", cb => sub { INFO "Exiting on SIGTERM"; exit 1; } );

    # loop forever. sorry callers.
    AnyEvent->condvar->recv;
}

sub generate {
    my ( $self ) = @_;

    if( $self->{'need_gc'} || defined $self->{'generate_cv'} ) {
        # peace out. also return nothing.
        TRACE "generate: doing nothing (another is already in flight or we are waiting for GC)";
        return;
    }

    # Start "generate" timer
    my $gtod_start = [gettimeofday];

    # Condvar that callers can use to wait for this job to finish. sends nothing of interest.
    my $ret_cv = AnyEvent->condvar;

    # @metafiles -- all generation targets

    my @metafiles = grep { $_->needs_generate } grep { defined $_ } values %{ $self->{'metafiles'} };
    if( @metafiles ) {
        DEBUG "generate: # targets = " . scalar( @metafiles );
    } else {
        TRACE "generate: no targets";
        $ret_cv->send;
        return $ret_cv;
    }

    # Clear the needs_generate flag on each of @targets.
    # Must be done before the generate job starts, in case someone wants to turn it back on
    # while the job is running (in that case, we need it to trigger another generate run
    # immediately afterwards).

    $_->needs_generate( 0 ) for @metafiles;

    # Split @metafiles up into chunks to be processed in parallel
    my $threads = $self->engine->config( 'generate_threads' ) || 1;

    # In case of serious error in the threads, this variable will be set
    my $generate_error;

    # Generation chunk results will go in here (see generate_exec comment for format)
    my $generate_result = undef;

    # Tracker condvar for all generation chunks
    $self->{'generate_cv'} = AnyEvent->condvar;
    $self->{'generate_cv'}->begin;

    # Start the threads.
    my $metafiles_chunk_sz = ceil(@metafiles/$threads);
    for( my $metafiles_chunk_start = 0 ; $metafiles_chunk_start < @metafiles ; $metafiles_chunk_start += $metafiles_chunk_sz) {
        my $metafiles_chunk_end = $metafiles_chunk_start + $metafiles_chunk_sz - 1;
        if( $metafiles_chunk_end >= @metafiles ) {
            $metafiles_chunk_end = @metafiles - 1;
        }

        my @metafiles_chunk = @metafiles[ $metafiles_chunk_start .. $metafiles_chunk_end ];

        $self->{'generate_cv'}->begin;

        # Compute raws needed by this metafile chunk (so we can pass it to generate_exec)
        my %raws_chunk;
        foreach my $metafile ( @metafiles_chunk ) {
            for my $raw_name ( $metafile->raw_needed ) {
                next if !$self->{'raws'}{$raw_name};
                $raws_chunk{$raw_name} ||= $self->{'raws'}{$raw_name};
            }
        }

        my $cv2 = $self->generate_exec(
            {
                raws => \%raws_chunk,
                targets => [ map +{ transforms => [ $_->transforms ], file => $_->name }, @metafiles_chunk ]
            }
        );

        $cv2->cb(
            sub {
                my $chunk_result = shift->recv;

                if( !defined $chunk_result || ref $chunk_result ne 'ARRAY' ) {
                    # Serious error.
                    ERROR "generate_exec: not an ARRAY ref";
                    $generate_error = 1;
                } elsif( @metafiles_chunk != @$chunk_result ) {
                    # Bug if this ever happens.
                    ERROR 'INTERNAL ERROR: Size of @metailes_chunk ['
                      . ( scalar @metafiles_chunk )
                      . '] does not match return from generate_exec ['
                      . ( scalar @$chunk_result ) . ']!';
                    $generate_error = 1;
                } else {
                    # Looks OK.
                    # Associate each returned target with a metafile, and merge into $generate_result
                    for( my $i = 0 ; $i < @metafiles_chunk ; $i++ ) {
                        $generate_result->{ $metafiles_chunk[$i]->id } = $chunk_result->[$i];
                    }
                }

                $self->{'generate_cv'}->end;
                undef $cv2;
            }
        );
    }

    # Cleanup code for the threads.
    $self->{'generate_cv'}->cb(
        sub {
            if( $generate_error ) {
                # Serious error. Restore needs_generate flag and abort.
                ERROR "generate: Run aborted due to fatal error!";
                $_->needs_generate( 1 ) for @metafiles;
            } else {
                eval {
                    # Process $generate_result

                    while( my ( $metafile_id, $metafile_result ) = each %$generate_result ) {
                        my $mf = $self->{'metafiles'}{$metafile_id};
                        next if !$mf;    # Maybe it was garbage collected?

                        my $was_updated; # true/false. set to correct value shortly

                        if( $metafile_result->{'ok'} ) {
                            # Generation went ok. Was this metafile updated?
                            if(
                                !$mf->is_usable    # wasn't previously usable
                                or ( ( $metafile_result->{'blob'} || '' ) ne ( $mf->blob || '' ) )    # blob sha changed
                              )
                            {
                                # Yes, it was updated

                                # XXX This says "ERR -> ablob" even if the initial state was unusable
                                # XXX due to never being generated. Strictly speaking that is incorrect

                                DEBUG "Metafile [$metafile_id] updated from "
                                  . ( !$mf->is_usable ? 'ERR' : ( $mf->blob || 'NULL' ) ) . " -> "
                                  . ( $metafile_result->{'blob'} || 'NULL' );

                                # Update metafile object
                                $mf->blob( $metafile_result->{'blob'} );

                                # Remember that it was updated
                                $was_updated = 1;
                            }
                        } else {
                            # Generation did not go ok. Is this news?

                            my $error_bucket = $self->error_bucket( $metafile_result->{'message'} );

                            if(
                                $mf->is_usable    # was previous usable
                                or ( ( $mf->error_bucket || '' ) ne $error_bucket )    # error message changed
                              )
                            {
                                # Yes, it's news.
                                $mf->error_bucket( $self->error_bucket( $metafile_result->{'message'} ) );
                                $was_updated = 1;
                            }

                            # Either way, report an error message.
                            my $message =
                              $self->scrub_error( $metafile_result->{'message'} || "Something went wrong!" );
                            ERROR "Generation error on [$metafile_id] : [$message]";
                        }

                        # If the metafile was updated, mark all of its transformsets as needing a repack
                        # For usable metafiles, this will lead to repacking
                        # For unusable metafiles, this will lead to nuking hosts' buckets

                        if( $was_updated && defined $self->{'metafile_transformset'}{ $mf->id } ) {
                            foreach my $transformset ( @{ $self->{'metafile_transformset'}{ $mf->id } } ) {
                                next if !defined $transformset;    # in case a reference was collected
                                $transformset->needs_pack( $transformset->needs_pack + 1 );
                            }
                        }
                    }

                    # Stop "generate" timer
                    DEBUG sprintf "generate done [metafiles %d] [elapsed_sec %0.3f]", ( scalar @metafiles ),
                      tv_interval( $gtod_start );

                    1;
                } or do {
                    # Error here is serious enough to stop the show, since it means failure of atomicity
                    FATAL "ABORT: Bailing out to avoid a partially executed transaction! [$@]";
                    exit 1;
                };
            }

            # Allow this job to run again
            undef $self->{'generate_cv'};

            # signal to callers that the job is done (if they were interested)
            $ret_cv->send;
        }
    );

    # One last end, to match the first begin.
    $self->{'generate_cv'}->end;

    return $ret_cv;
}

# Start a generation job
# Input: Same as Generator->generate
# Output: Condvar that sends output of Generator->generate OR, undef in case of fatal error.
# Does not modify any of the metafiles, or anything really.
sub generate_exec {
    my ( $self, $generator_input ) = @_;

    # Will be signaled with Generator->generate output
    my $cv = AnyEvent->condvar;

    # Downconvert Transform objects to plain hashes.
    # They're embedded inside 'targets' so pull them out first, then downconvert.
    foreach my $target ( @{ $generator_input->{'targets'} } ) {
        foreach my $transform ( @{ $target->{'transforms'} } ) {
            $generator_input->{'transforms'}{ $transform->id } ||=
              { name => $transform->name, yaml => $transform->yaml };

            # XXX HACKTOWN:
            $generator_input->{'module_conf'} ||= $transform->{'module_conf'};
        }

        @{ $target->{'transforms'} } = map $_->id, @{ $target->{'transforms'} };
    }

    # Storable input to doozer-build-generate
    my $input_stor = Storable::nfreeze( $generator_input );

    # Storable output of doozer-build-generate (eventually)
    my $output_stor;

    my $cv2 = AnyEvent::Util::run_cmd( [ 'doozer', 'build-generate' ], '>', \$output_stor, '<', \$input_stor );
    $cv2->cb(
        sub {
            my $rc = shift->recv;    # returns $?

            if( $rc != 0 ) {
                # failure! oh no!
                ERROR "doozer build-generate dead (code=$rc)";
                $cv->send( undef );
            } else {
                # not a failure

                my $output_obj;

                eval { $output_obj = Storable::thaw( $output_stor ); } or do {
                    ERROR "doozer build-generate output garbled [$@]";
                    $output_obj = undef;
                };

                $cv->send( $output_obj );
            }

            undef $cv2;
        }
    );

    return $cv;
}

sub pack {
    my ( $self ) = @_;

    if( $self->{'need_gc'} || defined $self->{'pack_cv'} ) {
        # peace out. also return nothing.
        TRACE "pack: doing nothing (another is already in flight or we are waiting for GC)";
        return;
    }

    # Start "pack" timer
    my $gtod_start = [gettimeofday];

    # Condvar that callers can use to wait for this job to finish. sends nothing of interest.
    my $ret_cv = AnyEvent->condvar;

    # Pack concurrency
    my $threads = $self->engine->config( 'pack_threads' ) || 1;

    # All pack targets. Hash of transformset ID -> hosts that need it + transformset object
    my %targets;

    # Are we going to need to commit error buckets?
    my $there_were_error_buckets = 0;

    keys %{$self->{'transformsets'}};
    while( my ( undef, $transformset ) = each %{$self->{'transformsets'}}) {
        # Check if we want to pack this transformset
        if( $transformset && $transformset->is_good && $transformset->needs_pack ) {
            # Answer is... maybe.

            if( my ( @mf_unusable ) = grep { !$_->is_usable } $transformset->metafiles ) {
                # Some metafiles in the transformset are unusable -- and they're stored in @mf_unusable
                # We can't pack this transformset. Remove it from the queue.
                $transformset->needs_pack( 0 );

                # Are the bad metafiles unusable due to errors, or just because they're new?
                # If error: we need to mark the hosts as having issues
                # If they're just new: don't do anything yet -- leave the hosts unchanged until the metafiles are available

                if( my ( $mf_error ) = grep { $_->error_bucket } @mf_unusable ) {
                    # At least one of the metafiles had an error -- and it's stored in $mf_error
                    # - Set host buckets to error_bucket
                    # - Set host error flags
                    foreach my $host_obj ( $transformset->hosts ) {
                        $self->workspace->write_host( $host_obj->name, $mf_error->error_bucket );
                    }

                    # Remember that we need to commit this.
                    $there_were_error_buckets = 1;
                }
            } else {
                # Looks good.
                $targets{ $transformset->id } = {
                    'object'          => $transformset,
                    'needs_pack_orig' => $transformset->needs_pack,
                    'hosts'           => [ $transformset->hosts ],
                };
            }
        }
    }

    if( !%targets ) {
        # There are no valid targets.

        if( $there_were_error_buckets ) {
            # However, there were targets marked as 'no', so we need to commit now.
            # Host buckets may have changed due to error_bucket updates above.
            $self->commit;
        }

        # No need to continue since there are no valid targets.

        TRACE "pack: no targets";
        $ret_cv->send;
        return $ret_cv;
    }

    # XXX is this the right number?
    my $MAX_TARGETS = $threads * 200;
    if( values %targets > $MAX_TARGETS ) {
        # Heuristic: Transformsets with more reasons to need packing are more important.
        # When a mass update is going on (DEFAULT, Keykeeper, etc) this should cause transformsets
        # with regular updates pending to bump to the front of the queue.

        my @top_targets = sort { $b->{'needs_pack_orig'} <=> $a->{'needs_pack_orig'} } values %targets;
        @top_targets = @top_targets[ 0 .. ( $MAX_TARGETS - 1 ) ];
        %targets = map { $_->{'object'}->id => $_ } @top_targets;
    }

    DEBUG "pack: # targets = " . ( scalar keys %targets );

    # Tracker condvar for all pack chunks
    $self->{'pack_cv'} = AnyEvent->condvar;
    $self->{'pack_cv'}->begin;

    # Common VERSION used by all targets
    my $version = $self->{checkout_version} || 0;

    # Start the threads.
    my @targets_list = values %targets;
    my $targets_chunk_sz = ceil(@targets_list/$threads);
    for( my $targets_chunk_start = 0 ; $targets_chunk_start < @targets_list ; $targets_chunk_start += $targets_chunk_sz) {
        my $targets_chunk_end = $targets_chunk_start + $targets_chunk_sz - 1;
        if( $targets_chunk_end >= @targets_list ) {
            $targets_chunk_end = @targets_list - 1;
        }

        my @targets_chunk = @targets_list[ $targets_chunk_start .. $targets_chunk_end ];

        $self->{'pack_cv'}->begin;

        # XXX lame. Need to reformat targets from @targets_chunk a bit
        my $targets_chunk_reformat = [];

        foreach my $target ( @targets_chunk ) {

            # Extract 'files' from the TransformSet ('object')
            my $target_files = [];
            push @$target_files, map +{ name => $_->name, blob => $_->blob },
              grep { defined $_->blob } $target->{'object'}->metafiles;

            # Map in transforms-index
            # XXX this is sort of lame
            push @$target_files,
              +{
                name => ".bucket/transforms-index",
                blob => $self->workspace->store_blob(
                    JSON::XS->new->encode( [ map { $_->name } $target->{'object'}->transforms ] )
                )
              };

            # Map in transforms
            # XXX this is sort of lame
            push @$target_files,
              map +{ name => ".bucket/transforms/" . $_->name, blob => $_->yamlblob }, $target->{'object'}->transforms;

            # Insert into $targets_chunk_reformat
            push @$targets_chunk_reformat,
              {
                hosts => [ map { $_->name } @{ $target->{'hosts'} } ],
                files => $target_files,
              };
        }

        my $repo_url = $self->engine->config( "svn_url" );
        $repo_url =~ s!://[\w\-]+\@!://!g;
        my $cv2 = $self->pack_exec(
            {
                repo    => "URL: $repo_url\n",        # XXX Missing "Revision"
                version => "$version\n",
                targets => $targets_chunk_reformat,
            }
        );

        $cv2->cb(
            sub {
                my $chunk_result = shift->recv;

                if( !defined $chunk_result || ref $chunk_result ne 'ARRAY' ) {
                    # Serious error.
                    ERROR "pack_exec: not an ARRAY ref";
                } elsif( @targets_chunk != @$chunk_result ) {
                    # Bug if this ever happens.
                    ERROR 'INTERNAL ERROR: Size of @targets_chunk ['
                      . ( scalar @targets_chunk )
                      . '] does not match @$chunk_result ['
                      . ( scalar @$chunk_result ) . ']!';
                } else {
                    # Looks OK.
                    # Update hosts @targets_chunk using $chunk_result.

                    for( my $i = 0 ; $i < @targets_chunk ; $i++ ) {
                        my $target        = $targets_chunk[$i];
                        my $target_result = $chunk_result->[$i];

                        # Decrement needs_pack on this target by needs_pack_orig.

                        $target->{'object'}
                          ->needs_pack( $target->{'object'}->needs_pack - $target->{'needs_pack_orig'} );

                        if( $target_result->{'ok'} ) {
                            # $target_result->{'bucket'} contains the new tree sha

                            foreach my $host_obj ( @{ $target->{'hosts'} } ) {
                                $self->workspace->write_host( $host_obj->name, $target_result->{'bucket'} );
                            }
                        } else {
                            # Packing error. Set error_bucket and error flag for these hosts.
                            foreach my $host_obj ( @{ $target->{'hosts'} } ) {
                                $self->workspace->write_host( $host_obj->name,
                                    $self->error_bucket( $target_result->{'message'} ) );
                            }

                            # And report the error.
                            my $message = $self->scrub_error( $target_result->{'message'} );
                            ERROR "Pack error on [" . $target->{'object'}->id . "] : [$message]";
                        }
                    }
                }

                $self->{'pack_cv'}->end;
                undef $cv2;
            }
        );
    }

    # Cleanup code for the threads.
    $self->{'pack_cv'}->cb(
        sub {

            # Commit updates
            $self->commit;

            # Log message
            DEBUG sprintf "pack done [targets %d] [elapsed_sec %0.3f]", ( scalar keys %targets ),
              tv_interval( $gtod_start );

            # Allow this job to run again
            undef $self->{'pack_cv'};

            # signal to callers that the job is done (if they were interested)
            $ret_cv->send;
        }
    );

    # One last end, to match the first begin.
    $self->{'pack_cv'}->end;

    return $ret_cv;
}

# Start a pack job
# Input: Same as Packer->pack
# Output: Condvar that sends output of Packer->pack OR, undef in case of fatal error.
# Does not modify any of the input objects, or anything really.
sub pack_exec {
    my ( $self, $packer_input ) = @_;

    my $cv = AnyEvent->condvar;

    # Storable input to doozer-build-pack
    my $input_stor = Storable::nfreeze( $packer_input );

    # Storable output of doozer-build-pack (eventually)
    my $output_stor;

    my $cv2 = AnyEvent::Util::run_cmd( [ 'doozer', 'build-pack' ], '>', \$output_stor, '<', \$input_stor );
    $cv2->cb(
        sub {
            my $rc = shift->recv;    # returns $?

            if( $rc != 0 ) {
                # failure! oh no!
                ERROR "doozer build-pack dead (code=$rc)";
                $cv->send( undef );
            } else {
                # not a failure

                my $output_obj;

                eval { $output_obj = Storable::thaw( $output_stor ); } or do {
                    ERROR "doozer build-pack output garbled [$@]";
                    $output_obj = undef;
                };

                $cv->send( $output_obj );
            }

            undef $cv2;
        }
    );

    return $cv;
}

# Grab all inputs:
# - List of hosts to build from ZooKeeper
# - Host->transform maps, and raw files, from the Checkout tarball
sub checkout {
    my ( $self ) = @_;

    # Start timer
    my $gtod_start = [gettimeofday];

    # Connect to ZooKeeper
    my $zk = $self->engine->new_zookeeper_worker;

    # Location of checkout tarball
    my $checkout_tar =
      $self->engine->config( "var" ) . "/dropbox/checkout-" . ( $zk->config( "pusher" ) // "" ) . ".tar";

    # We'll use this variable to hold a temp dir for the checkout tarball, if needed
    my $checkout_tmp;

    # Lazy unpacker for $checkout_tar into $checkout_tmp
    # XXX should use CheckoutPack
    my $checkout_unpack = sub {
        if( !$checkout_tmp ) {
            $checkout_tmp = File::Temp->newdir( CLEANUP => 1 );
            system( "tar", "-xf", $checkout_tar, "-C", $checkout_tmp->dirname );
            if( $? ) {
                undef $checkout_tmp;
                LOGDIE "tar -xf $checkout_tar failed!\n";
            }
        }
    };

    # Condvar will be returned, and signalled when we are done
    my $cv = AnyEvent->condvar;

    # Has the checkout tarball been updated recently?
    my @checkout_stat = stat $checkout_tar;
    my $checkout_updated;
    if(
        @checkout_stat
        and (  !$self->{checkout_tar}
            or !$self->{checkout_mtime}
            or $checkout_tar ne $self->{checkout_tar}
            or $self->{checkout_mtime} != $checkout_stat[9] )
      )
    {
        DEBUG "Checkout tarball updated (path = $checkout_tar, mtime = $checkout_stat[9])";
        $checkout_updated = $checkout_stat[9];
    }

    # Update $self->{hosts}, $self->{transforms}, $self->{transformsets}
    # Based on our partition from ZooKeeper and the host -> transform map from Checkout
    do {
        # Load our partition from ZooKeeper (list of hostnames we should build for)
        my $zpart = [ $zk->get_part ];

        # Remove obsolete host objects from $self->{hosts}
        # XXX nothing triggers a commit for this change -- it has to wait until pack() wants to commit something
        my %zpart_lookup = map { $_ => 1 } @$zpart;
        foreach my $host ( keys %{ $self->{hosts} } ) {
            if( !$zpart_lookup{$host} ) {
                $self->workspace->write_host( $host, undef );
                delete $self->{hosts}{$host};
            }
        }

        # We need to load the host -> transforms map in two cases:
        # - Checkout tarball was updated
        # - ZooKeeper gave us new hosts we haven't heard of before
        
        if( $checkout_updated or ( my @new_hosts = grep { ! $self->{'hosts'}{$_} } @$zpart ) ) {
            $checkout_unpack->();
            my $host_transforms = YAML::XS::LoadFile( "$checkout_tmp/hosts.idx" );

            my $hosts_to_iterate = $checkout_updated ? [ keys %$host_transforms ] : \@new_hosts;
          HOST: for my $hostname ( @$hosts_to_iterate ) {
                if( !$zpart_lookup{$hostname} ) {
                    # Not our problem
                    next HOST;
                }

                # Host object for this particular $hostname
                my $host_obj = $self->host( $hostname );

                # Get transforms according to the hosts -> transform map from Checkout
                my $transforms = $host_transforms->{$hostname};

                # Null set of transforms is a special case meaning "build nothing"
                if( !$transforms || !@$transforms ) {
                    $host_obj->clear;
                    $self->workspace->write_host( $host_obj->name, undef );
                    next HOST;
                }

                # Read transforms for this host, if needed
                # Need to keep a reference to any new ones for now so they don't get removed by the refcounter
                my @new_transform_objects;
                foreach my $transform ( @$transforms ) {
                    if( ! defined $self->{'transforms'}{$transform} ) {
                        # Yeah it's needed
                        my ( $tname, $tblob ) = ( $transform =~ /^(.+)\@([a-z0-9]{40})\z/ );
                        my $tpath = "$checkout_tmp/obj/$tblob";

                        open my $tfh, "<", $tpath
                          or LOGDIE "open $tpath: $!\n";
                        my $tcontents = do { local $/; <$tfh> };
                        close $tfh;

                        my $transform_obj = Chisel::Transform->new(
                            name        => $tname,
                            yaml        => $tcontents,
                            module_conf => $self->{module_conf}
                        );

                        # XXX this was done to make .bucket directory work. Is it necessary?
                        $self->workspace->store_blob( $transform_obj->yaml ) eq $transform_obj->yamlblob
                          or LOGDIE "Transform [$transform] did not serialize to the correct blob SHA!";

                        push @new_transform_objects, $transform_obj; # will be discarded soon
                        $self->{'transforms'}{$transform} = $transform_obj;
                        Scalar::Util::weaken( $self->{'transforms'}{$transform} );
                    }
                }

                # Figure out transform set for this host
                my $transformset = $self->transformset( @$transforms );

                # Now safe to discard references in @new_transform_objects
                @new_transform_objects = ();

                # Check if this is a new transformset for $host_obj
                if( !$host_obj->transformset || $host_obj->transformset->id ne $transformset->id ) {
                    # It's new. Assign it and re-pack the transformset
                    $host_obj->transformset( $transformset );

                    if( $transformset->is_good ) {
                        $transformset->needs_pack( $transformset->needs_pack + 1 );
                    } else {
                        # This TransformSet is bad.
                        # Just set error_bucket for the node as a message to that effect.
                        $self->workspace->write_host( $host_obj->name, $transformset->error_bucket );
                    }
                }
            }
        }
    };

    # Check for updated raw files
    # While keeping track of raw files that have changed in some way
    my %raw_changed;

    if( $checkout_updated ) {
        # Yeah let's do it.
        $checkout_unpack->();

        # Read the raw file index
        my $raw_index = YAML::XS::LoadFile( "$checkout_tmp/raw.idx" );

        # Update all changed raw files
        while( my ( $raw_name, $raw_info ) = each( %$raw_index ) ) {
            my $bold = $self->{'raws'}{$raw_name};
            my $bnew = $raw_info->{'blob'};

            if(
                ( defined $bnew && !defined $bold )       # NOT NULL -> NULL
                or ( !defined $bnew && defined $bold )    # NULL -> NOT NULL
                or ( defined $bnew && defined $bold && $bnew ne $bold )    # value -> another value
              )
            {
                # $raw_name is different in some way
                DEBUG "Raw file [$raw_name] updated";

                $raw_changed{$raw_name} = 1;

                if( defined $bnew ) {
                    # Read contents off disk and write to workspace
                    my $raw_path = "$checkout_tmp/obj/$bnew";
                    open my $raw_fh, "<", $raw_path
                      or LOGDIE "open $raw_path: $!\n";

                    my $raw_data = do { local $/; <$raw_fh> };
                    close $raw_fh;

                    $self->workspace->store_blob( $raw_data );
                    $self->{'raws'}{$raw_name} = $bnew;
                } else {
                    delete $self->{'raws'}{$raw_name};
                }

            }
        }

        # Delete all obsolete raw files
        foreach my $raw_name ( keys %{ $self->{'raws'} } ) {
            if( !$raw_index->{$raw_name} || !$raw_index->{$raw_name}{blob} ) {
                $raw_changed{$raw_name} = 1;
                delete $self->{'raws'}{$raw_name};
            }
        }
    }

    # Possibly update $self->{checkout_version}, $self->{checkout_mtime}, $self->{checkout_path}
    if( $checkout_updated ) {
        $checkout_unpack->();

        open my $vfh, "<", "$checkout_tmp/version"
          or LOGDIE "open $checkout_tmp/version: $!\n";
        my $version = do { local $/; <$vfh> };
        if( $version =~ /^(\d+)$/ ) {
            $self->{checkout_version} = $1;
        } else {
            LOGDIE "Invalid checkout version [$version]";
        }

        $self->{checkout_mtime} = $checkout_updated;
        $self->{checkout_tar}   = $checkout_tar;

        DEBUG "Checkout VERSION is now: $self->{checkout_version}";
    }

    # Turn on needs_generate for any metafiles that satisfy EITHER:
    #  - Depends on a raw file which has changed
    #  - Have never been generated (Metafiles start off with needs_generate = 0; we were waiting
    #    until now to turn it on so we had a chance to fetch raw files)
    foreach my $metafile ( values %{ $self->{'metafiles'} } ) {
        next if !defined $metafile;
        if( $metafile->is_new or any { $raw_changed{$_} } $metafile->raw_needed ) {
            $metafile->needs_generate( 1 );
        }
    }

    DEBUG sprintf "checkout done [elapsed_sec %0.3f]", tv_interval( $gtod_start );

    # Signal the condvar and return
    $cv->send;
    return $cv;
}

sub gc {
    my ( $self ) = @_;

    my $gtod_start = [gettimeofday];

    DEBUG "gc: start";

    # Remove empty keys left behind by weak references
    for my $hash ( qw/metafile_transformset transforms metafiles transformsets/ ) {
        keys %{ $self->{$hash} };
        while( my ( $k, $v ) = each %{ $self->{$hash} } ) {
            if( !defined $v || ( $hash eq 'metafile_transformset' && !any { defined $_ } @$v ) ) {
                delete $self->{$hash}{$k};
            }
        }
    }

    # Workspace garbage collection (remove unused files from the filesystem)
    my $ws = $self->workspace;

    my ( @keep_files, @keep_buckets );

    # Keep files corresponding to all our raws
    DEBUG "gc: workspace: keep: scanning raws";
    push @keep_files, values %{ $self->{'raws'} };

    # Keep files corresponding to all our metafiles
    DEBUG "gc: workspace: keep: scanning metafiles";
    push @keep_files, grep { defined $_ } map { $_->blob } grep { $_->is_usable } values %{ $self->{'metafiles'} };

    # Keep files corresponding to our transforms
    DEBUG "gc: workspace: keep: scanning transforms";
    push @keep_files, map { $_->yamlblob } values %{ $self->{'transforms'} };

    # Keep error_buckets for all transform sets and metafiles
    DEBUG "gc: workspace: keep: scanning error buckets";
    for my $ebid (
        grep { defined $_ }
        map { $_->error_bucket } ( values %{ $self->{'transformsets'} }, values %{ $self->{'metafiles'} } )
      )
    {
        my $eb = $ws->bucket( $ebid );
        push @keep_buckets, $ebid;
        push @keep_files, map { $_->{'blob'} } values %{ $eb->manifest( include_dotfiles => 1, emit => ['blob'] ) };
    }

    # Perform workspace garbage collection
    DEBUG "gc: workspace: begin cleaning";
    $ws->gc( keep_files => \@keep_files, keep_buckets => \@keep_buckets );

    # End of GC is a convenient time to update metrics, since fluff has been removed
    $self->metrics->set_metric( {}, "n_hosts",      scalar values %{ $self->{'hosts'} } );
    $self->metrics->set_metric( {}, "n_buckets",    scalar values %{ $self->{'transformsets'} } );
    $self->metrics->set_metric( {}, "n_transforms", scalar values %{ $self->{'transforms'} } );
    $self->metrics->set_metric( {}, "n_metafiles",  scalar values %{ $self->{'metafiles'} } );

    # Also write metrics to yaml files on disk for monitoring (bug 4676770)
    eval {
        my $statusdir = $self->engine->config( "var" ) . "/status";

        # "metrics"
        open my $fh, ">", "$statusdir/metrics.$$"
          or die "open $statusdir/metrics.$$: $!\n";
        print $fh YAML::XS::Dump(
            {
                n_nodes         => scalar values %{ $self->{'hosts'} },
                n_nodes_ignored => 0,
            }
        );
        close $fh;
        rename "$statusdir/metrics.$$" => "$statusdir/metrics"
          or die "can't replace $statusdir/metrics: $!\n";

        # "metrics-build"
        unless( -l "$statusdir/metrics-build" and readlink "$statusdir/metrics-build" eq "metrics" ) {
            unlink "$statusdir/metrics-build";
            symlink "metrics", "$statusdir/metrics-build"
              or die "symlink $statusdir/metrics-build -> metrics: $!\n";
        }

        # "metrics-checkout" is updated by doozer-checkout, nothing to do here

        1;
    } or do {
        ERROR "Cannot update metrics files: $@";
    };

    DEBUG sprintf "gc done [elapsed_sec %0.3f]", tv_interval( $gtod_start );

    return;
}

# Commits our current nodemap
sub commit {
    my ( $self ) = @_;

    # Update nodemap-mirror.mdbm
    $self->workspace->commit_mirror;
}

# Returns host object based on hostname.
# Adds to $self->{'hosts'} if needed.
# Dies on failure.
sub host {
    my ( $self, $hostname ) = @_;

    return $self->{'hosts'}{$hostname} ||= Chisel::Builder::Overmind::Host->new( name => $hostname );
}

# Returns transform object based on transform ID.
# Dies on failure.
sub transform {
    my ( $self, $transform_id ) = @_;

    if( defined $self->{'transforms'}{$transform_id} ) {
        return $self->{'transforms'}{$transform_id};
    } else {
        LOGDIE "Transform [$transform_id] does not exist!";
    }
}

# Returns metafile object based on metafile ID.
# Adds to $self->{'metafiles'} if needed.
# Dies on failure.
sub metafile {
    my ( $self, $metafile_name, @metafile_transforms ) = @_;

    my $metafile_id = Chisel::Builder::Overmind::Metafile->idfor( $metafile_name, @metafile_transforms );

    if( defined $self->{'metafiles'}{$metafile_id} ) {
        return $self->{'metafiles'}{$metafile_id};
    } else {
        DEBUG "New Metafile [$metafile_id]";

        my $mf = Chisel::Builder::Overmind::Metafile->new(
            name       => $metafile_name,
            transforms => \@metafile_transforms
        );

        $self->{'metafiles'}{$metafile_id} = $mf;

        Scalar::Util::weaken( $self->{'metafiles'}{$metafile_id} );
        return $mf;
    }
}

sub transformset {
    my ( $self, @transforms ) = @_;

    # figure out transform set ID
    my $transformset_id = Chisel::Builder::Overmind::TransformSet->idfor( @transforms );

    if( defined $self->{'transformsets'}{$transformset_id} ) {
        return $self->{'transformsets'}{$transformset_id};
    } else {
        DEBUG "New TransformSet [$transformset_id]";

        # get transform objects out of $self->transform
        # @transforms could be IDs, or could be real objects; either way we want to make sure all transformsets
        # with a particular transform ID share the same transform object.

        @transforms = map { $self->transform( $_ ) } @transforms;

        my $tset = $self->{'transformsets'}{$transformset_id} = Chisel::Builder::Overmind::TransformSet->new(
            transforms => \@transforms,
            mfsub      => sub { $self->metafile( @_ ) },
            ebsub      => sub { $self->error_bucket( @_ ) },
        );

        # keep $self->{'metafile_transformset'} index up-to-date
        for my $mf ($tset->metafiles) {
            push @{ $self->{'metafile_transformset'}{ $mf->id } }, $tset;
            Scalar::Util::weaken( $self->{'metafile_transformset'}{ $mf->id }[-1] );
        }

        # weaken reference in the index
        Scalar::Util::weaken($self->{'transformsets'}{$transformset_id});

        return $tset;
    }
}

# Scrubs possibly sensitive strings from error messages.
sub scrub_error {
    my ( $self, $message ) = @_;
    return $self->engine->scrub_error( $message );
}

# Creates and commits a bucket to git containing a particular error message (and nothing else)
# Returns the bucket tree sha
sub error_bucket {
    my ( $self, $message ) = @_;

    my $bucket = Chisel::Bucket->new;
    $bucket->add( file => '.error', blob => $self->workspace->store_blob( $self->scrub_error( $message ) . "\n" ) );
    $self->workspace->store_bucket( $bucket );
    return $bucket->tree;
}

# Set up an AnyEvent timer
sub timer {
    my ( $self, %args ) = @_;

    my $name  = delete $args{'name'};
    my $oldcb = delete $args{'cb'};

    $args{'cb'} = sub {
        eval {
            TRACE "ENTER TIMER $name";
            $oldcb->();
            TRACE "EXIT TIMER $name";
            1;
        } or do {
            ERROR "${name}_timer: $@";
        };
    };

    return AnyEvent->timer( %args );
}

sub engine    { shift->{engine_obj} }
sub metrics   { shift->engine->metrics }
sub workspace { shift->{workspace_obj} }

1;
