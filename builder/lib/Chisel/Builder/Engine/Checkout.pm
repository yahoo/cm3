######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Engine::Checkout;

# this package is meant to read information out of a svn repository, as well as any needed "virtual" raw files like usergroups
#
# inputs:  transformdir + rawdir + scriptdir + cmdb/roles credentials
# outputs: transform objects, tag objects, all necessary raw files

use strict;
use warnings;
use Chisel::Builder::Raw;
use Chisel::Tag;
use Chisel::Metrics;
use Chisel::Transform;
use Regexp::Chisel qw/ :all /;
use Carp;
use Log::Log4perl qw/:easy/;
use Hash::Util ();
use YAML::XS ();

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # inputs
        tagdir            => '',        # directory that tags live in
        transformdir      => '',        # directory that transforms live in
        scriptdir         => '',        # directory that modules live in

        # obj to read raw files out of
        rawobj            => undef,     # normally passed in by Engine

        # set of ex-raw files from the last round
        # used to provide context to the rawobj, for caching and sanity checking
        ex_raws           => [],

        # Chisel::Metrics object for storing metrics
        metrics_obj       => undef,
    };

    my $self = { %$defaults, %rest };

    # create objects that we need but weren't given to us
    if( !$self->{metrics_obj} ) {
        my ( $pkg, $file, undef ) = caller();
        TRACE "We weren't given a metrics object by package $pkg in file $file, creating dummy";
        $self->{metrics_obj} = Chisel::Metrics->new;
    }

    if( keys %$self > keys %$defaults ) {
        LOGDIE "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    # add internals
    %$self = (
        %$self,

        # internals and caches
        modules      => undef,    # $modules{ module name } => its module.conf
        transforms   => undef,    # array of Chisel::Transform objs
        tags         => undef,    # array of Chisel::Tag objs
    );

    bless $self, $class;
    Hash::Util::lock_keys(%$self);
    return $self;
}

# either:
#  - return contents of a raw file
#  - OR return array of ALL interesting raw files
sub raw {
    my ( $self, $ufile ) = @_;

    # lookup table of ex-raw-files (context for readraw later)
    my %ex_raw_lookup = map { $_->name => $_ } @{$self->{ex_raws}};

    if( @_ > 1 ) {
        # caller wanted one raw file object
        my $raw_obj = $self->{rawobj}->readraw($ufile, context => $ex_raw_lookup{$ufile});
        if( defined $raw_obj && defined $raw_obj->data ) {
            return $raw_obj;
        } else {
            die "file does not exist: $ufile";
        }
    } else {
        # fetch all raw file objects we care about (based on our transforms)
        my %raw_needed
            = map { $_ => 1 }           # remove duplicates by assigning to a hash
              map  { $_->raw_needed() } # all raw files needed by each transform
              grep { $_->is_good() }    # skip transforms that are unloadable
              $self->transforms;

        # now we're ready to fetch everything
        my @raws;
        foreach my $raw_name ( sort keys %raw_needed ) {
            my $raw_obj = $self->{rawobj}->readraw( $raw_name, context => $ex_raw_lookup{$raw_name} );
            if( defined $raw_obj ) {
                push @raws, $raw_obj;
            } else {
                WARN "Skipped nonexistent raw file $raw_name";
            }
        }

        return @raws;
    }
}

# returns our array of Tag objects, filling $self->{tags} if necessary
sub tags {
    my ( $self, %args ) = @_;

    if( ! defined $self->{tags} ) {
        # tags are stored in here
        my $tagdir = $self->{tagdir};

        DEBUG "Scanning tags in $tagdir";

        # we're going to read tags using a Chisel::Builder::Raw::Filesystem object
        # they're pretty convenient and make sure no shenanigans are happening
        my $tag_fs = Chisel::Builder::Raw::Filesystem->new( rawdir => $tagdir );

        # we'll put them in here
        my @tags;

        foreach my $tag ( glob "$tagdir/*" ) {
            # only look at regular files
            next unless -f $tag;

            # shorten the name, read it out of $tag_fs
            if( $tag =~ m{/($RE_CHISEL_tag_key)$} ) {
                my $shortname = $1;
                my $name = $shortname eq 'GLOBAL' ? 'GLOBAL' : "cmdb_property/$shortname";
                my $yaml = $tag_fs->fetch( $shortname );

                if( ! defined $yaml ) {
                    LOGDIE "Tag [$name] cannot be read from $tagdir!";
                }

                if( my @dupes = grep { lc "$_" eq lc $name } @tags ) {
                    # checking for "duplicate" tags (ones that match case-insensitively)
                    LOGDIE "Duplicate tag keys: $name, " . join( ", ", @dupes );
                }

                # looks ok
                push @tags, Chisel::Tag->new(
                    name => $name,
                    yaml => $yaml,
                );
            } else {
                WARN "Ignoring tag file: $tag";
            }
        }

        $self->metrics->set_metric( {}, 'n_tags', scalar @tags );
        $self->{tags} = \@tags;
    }

    return @{ $self->{tags} };
}


# returns our array of Transform objects, filling $self->{transforms} if necessary
sub transforms {
    my ( $self, %args ) = @_;

    if( ! defined $self->{transforms} ) { # fill $self->{transforms}
        my $transformdir = $self->{transformdir};

        my @t;     # transform names
        my @td;    # subdirs in transforms/

        DEBUG "Scanning transforms in $transformdir";

        opendir my $dir, $transformdir
          or confess( "Cannot open dir $transformdir" );

        foreach my $f ( readdir $dir ) {
            push @t,  $f if $f =~ /^$RE_CHISEL_transform$/      && -f "$transformdir/$f";
            push @td, $f if $f =~ /^$RE_CHISEL_transform_type$/ && -d "$transformdir/$f";
        }

        closedir $dir;

        # read subdirs (only one level deep)
        foreach my $d ( @td ) {
            opendir my $dir, "$transformdir/$d"
              or confess( "Cannot open dir $transformdir/$d" );

            push @t,
              map { "$d/$_" }
              grep { /^$RE_CHISEL_transform_key$/ && -f "$transformdir/$d/$_" }
              readdir $dir;
        }

        # we're going to read transforms using a Raw::Filesystem object
        # they're pretty convenient and make sure no shenanigans are happening
        my $transform_fs = Chisel::Builder::Raw::Filesystem->new( rawdir => $transformdir );

        # read module.confs for all modules, we'll need to pass it to the transform objects
        my %module_conf = map { $_ => $self->module( name => $_ ) } $self->modules;

        # we have a list of all transforms in @t, let's create a %transforms hash
        # it's ok for this to not include the contents, because this class deals only with one version of each
        # $transforms{ lc transform name } = transform object
        my %transforms;

        foreach my $ti (@t) {
            # read the yaml for this transform
            my $ti_yaml = $transform_fs->fetch( $ti );

            if( ! defined $ti_yaml ) {
                LOGDIE "Transform [$ti] cannot be read from $transformdir!";
            }

            # create a transform object
            my $transform = Chisel::Transform->new( name => $ti, yaml => $ti_yaml, module_conf => \%module_conf );

            # add it to %transforms
            confess "Duplicate transform key: $transform"
              if exists $transforms{ lc $transform->name };
            $transforms{ lc $transform->name } = $transform;
        }

        # add empty DEFAULT and DEFAULT_TAIL if there were no files for them
        $transforms{'default'} = Chisel::Transform->new( name => 'DEFAULT', yaml => '', module_conf => \%module_conf )
          if ! exists $transforms{'default'};

        $transforms{'default_tail'} = Chisel::Transform->new( name => 'DEFAULT_TAIL', yaml => '', module_conf => \%module_conf )
          if ! exists $transforms{'default_tail'};

        # informational message
        INFO "Read " . scalar( keys %transforms ) . " transforms";
        $self->metrics->set_metric( {}, 'n_transforms', scalar keys %transforms );

        # save the list
        $self->{transforms} = [ values %transforms ];
    }

    # return the transform objects
    return @{ $self->{transforms} };
}

# return a list of module names
sub modules {
    my ( $self, %args ) = @_;

    return keys %{$self->{modules}} if defined $self->{modules};

    my %module_conf;

    my $scriptdir = $self->{scriptdir};
    opendir my $dir, $scriptdir
      or confess( "Cannot open modules dir: $scriptdir" );

    my @scripts = grep { -d "$scriptdir/$_" && ! /^\./ } readdir $dir;
    closedir $dir;

    foreach my $s (@scripts) {
        DEBUG "Reading module.conf for $s";

        if( -f "$scriptdir/$s/module.conf" ) {
            eval {
                ( $module_conf{$s} ) = YAML::XS::LoadFile( "$scriptdir/$s/module.conf" );

                1;
            } or do {
                # YAML::XS::Load probably failed, die with a useful error
                confess "Error loading module.conf for $s!\n$@";
            };
        } else {
            $module_conf{$s} = {};
        }
    }

    Hash::Util::lock_keys( %module_conf );
    $self->{modules} = \%module_conf;
    return keys %module_conf;
}

# return configuration for a module, or undef if the module does not exist
sub module {
    my ( $self, %args ) = @_;
    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/name/;

    $self->modules if ! defined $self->{modules};

    return exists $self->{modules}{ $args{name} }
      ? $self->{modules}{ $args{name} }
      : undef;
}

# accessors
sub metrics    { return shift->{metrics_obj} }

1;
