######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Transform;

use warnings;
use strict;

use Carp;
use Digest::SHA1 ();
use Hash::Util;
use List::MoreUtils qw/ any /;
use Log::Log4perl qw/ :easy /;
use Scalar::Util ();
use Storable ();
use Text::Glob ();
use YAML::XS ();
use Chisel::Loadable;
use Regexp::Chisel qw/ :all /;

# print our name@blob when used as a string
# the idea here is this is a unique identifier
use overload '""' => \&id;

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # these should be given upfront
        name         => '',
        yaml         => '',
        module_conf  => {},     # module.conf structure (can change the way transforms are understood)
    };

    my $self = { %$defaults, %rest };
    if( keys %$self > keys %$defaults ) {
        LOGCROAK "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    # 'name' is required
    if( ! $self->{name} ) {
        LOGCROAK "transform 'name' not given";
    }

    # 'name' needs a certain format
    if( $self->{name} !~ /^$RE_CHISEL_transform\z/ ) {
        LOGCROAK "transform 'name' is not well-formatted: $self->{name}";
    }

    # set $self->{'yamlblob'} to a sha1 of its contents (in the git style)
    # TODO this can probably be lazy-loaded, available via yamlblob()
    $self->{yamlblob} = lc Digest::SHA1::sha1_hex( "blob " . ( length $self->{yaml} ) . "\0" . $self->{yaml} );

    # set $self->{'id'} to our id (see sub id)
    $self->{'id'} = $self->{'name'} . "@" . $self->{'yamlblob'};

    # bless $self before making a copy of it
    bless $self, $class;

    # weaken a copy of $self so we don't end up creating a circular reference in the closure below
    my $weakself = $self;
    Scalar::Util::weaken($weakself);

    # lazy loading of the parsed rules for this transform
    $self->{_loadable}
        = Chisel::Loadable->new( loader => sub { $weakself->_parse } );

    # lock %$self to prevent typos
    Hash::Util::lock_keys(%$self);
    Hash::Util::lock_value(%$self, $_) for keys %$self;
    return $self;
}

# return the identifier for this transform
# something like: func/BAR@4f097857906bbe2c2b8a9f5bc19f01506b1ac906
# this is unique based on the transform name/contents pair
sub id {
    my ( $self ) = @_;
    return $self->{'id'};
}

# return the name of this transform, as a string
# not including the @ $BLOB part
sub name {
    my ( $self ) = @_;
    return $self->{'name'};
}

# return the contents of this transform, as raw yaml
sub yaml {
    my ( $self ) = @_;
    return $self->{'yaml'};
}

# return just the yaml blob (hash)
sub yamlblob {
    my ( $self ) = @_;
    return $self->{'yamlblob'};
}

# the 'do it' method: actually transform a file from one state to another
# usage: $t->transform( file => "files/motd/MAIN", model => $transform_model, ctx => $generator );
# returns: 1 = success, 0 = stop and remove file, undef = error
sub transform {
    my ( $self, %args ) = @_;

    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/ file model /;

    if( ! $self->does_transform( file => $args{'file'} ) ) {
        LOGDIE "$self: asked to transform file [$args{file}] but do not know how";
    }

    my @rules = $self->rules( file => $args{'file'} );

    while (@rules) {
        # get the next rule
        my $rule = shift @rules;
        my ( $action, @rest ) = @$rule;

        # run it
        my $action_sub = "action_${action}";
        my $ret = $args{model}->$action_sub( @rest );

        if( !defined $ret || $ret != 1 ) {
            # something funky happened, return immediately
            return $ret;
        }
    }

    # return 1 since everything looks ok
    return 1;
}

sub is_loaded {
    my ( $self ) = @_;
    return $self->{_loadable}->is_loaded;
}

sub is_good {
    my ( $self ) = @_;
    return $self->{_loadable}->is_good;
}

sub error {
    my ( $self ) = @_;
    return $self->{_loadable}->error;
}

sub unload {
    my ( $self ) = @_;
    $self->{_loadable}->unload;
}

# generates "rules", and "metadata" based on "yaml" and "module_conf"
sub _parse {
    my ( $self, %args ) = @_;

    TRACE "Loading transform: " . $self->id;

    # this will die if the YAML is bad
    my ( $rules_in, $metadata ) = YAML::XS::Load( $self->{'yaml'} );
    $rules_in ||= {};
    $metadata ||= {};

    # ensure $metadata is in an ok format
    if( ref $metadata ne 'HASH' || grep { ref $_ ne 'ARRAY' } values %$metadata ) {
        LOGDIE "$self: meta section is not a key-to-list yaml map";
    }

    # normalize $rules_in
    my $rules_out = $self->_normalize_transform( $rules_in, no_dclone => 1 );

    return { rules => $rules_out, metadata => $metadata };
}

# retrieves metadata values by key name
# or empty list if there are none for that key
sub meta {
    my ( $self, %args ) = @_;

    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/key/;

    my $metadata = $self->{_loadable}->load->{metadata};

    if( $metadata->{$args{key}} ) {
        return @{ $metadata->{$args{key}} };
    } else {
        return ();
    }
}

# returns a list of file names that this transform cares about
sub files {
    my ( $self ) = @_;

    my $rules = $self->{_loadable}->load->{rules};
    return keys %$rules;
}

# returns true/false based on whether we transform a particular file
sub does_transform {
    my ( $self, %args ) = @_;
    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/file/;

    return exists $self->{_loadable}->load->{rules}{ $args{file} };
}

# returns the model that should be used for a particular file
# default: Text
sub model {
    my ( $self, %args ) = @_;
    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/file/;

    my ( $module, $filename ) = ( $args{'file'} =~ m!^files/($RE_CHISEL_filepart)/($RE_CHISEL_filepart)\z! );

    my $shortclass =
      (      $module
          && exists $self->{'module_conf'}{$module}
          && $self->{'module_conf'}{$module}{'model'}
          && $self->{'module_conf'}{$module}{'model'}{$filename} )
      || 'Text';

    my $class = 'Chisel::TransformModel::' . $shortclass;

    # load $class
    eval "require $class;" or die $@;

    # return class name
    return $class;
}

# returns a list of actions to run against a particular file
# will return an empty list of the file isn't part of this transform
sub rules {
    my ( $self, %args ) = @_;

    defined( $args{$_} ) or confess( "$_ not given" )
      for qw/file/;

    my $rules = $self->{_loadable}->load->{rules};

    if( exists $rules->{ $args{file} } ) {
        my $file_rules = $rules->{ $args{file} };
        return @$file_rules;
    } else {
        # return an empty list if we don't have this key
        return ();
    }
}

# returns a list of what raw filenames are needed to run this transform
# or, optionally, what is needed to generate a specific file from this transform
sub raw_needed {
    my ( $self, %args ) = @_;

    # hash to make it easy to dedupe
    my %raw_all;

    my $rules = $self->{_loadable}->load->{rules};

    # what files are we interested in?
    my @files = defined $args{'file'} ? $args{'file'} : ( keys %$rules );

    foreach my $file (@files) {
        # skip files we don't actually transform
        next if !exists $rules->{$file};

        # get TransformModel class for this $file
        my $modelclass = $self->model( file => $file );

        # loop over all rules for this file
        foreach my $rule (@{$rules->{$file}}) {
            # we're going to use $model->raw_needed to figure out what's up for this file.

            my @raw = $modelclass->raw_needed(@$rule);

            LOGDIE "raw_needed: cannot determine dependencies for @$rule"
              if grep { ! $_ } @raw;

            # XXX additionally, because of transforms like this:
            # XXX  /scripts/motd:
            # XXX      - use motd
            # XXX we have to know to translate "motd" here into "modules/motd/motd"

            if( $file =~ m{^scripts/([^/]+(?<!\.asc))(?:\.asc|)$} ) {
                @raw = map { "modules/$1/$_" } @raw;
            }

            $raw_all{$_} = 1 for @raw;
        }
    }

    return keys %raw_all;
}

# given a list of transform objects, sort them while respecting dependencies
# if called on an object, will include $self in this list. if called on the class, will not (since that makes no sense)
sub order {
    my ( $self, @transforms ) = @_;

    # figure out if $self is an object or not
    if( Scalar::Util::blessed($self) and $self->isa(__PACKAGE__) ) {
        @transforms = ( $self, @transforms );
    }

    # remove DEFAULT, DEFAULT_TAIL if present -- we'll add them back later.
    my ( $has_default )      = grep { $_->name eq "DEFAULT" } @transforms;
    my ( $has_default_tail ) = grep { $_->name eq "DEFAULT_TAIL" } @transforms;
    @transforms = grep { $_->name ne "DEFAULT" && $_->name ne "DEFAULT_TAIL" } @transforms;

    # build %deps to satisfy:
    # $deps{ transform identifier } = [ anything from @transforms which should precede our transform ]
    my %deps;

    foreach my $transform (@transforms) {
        my @follows = $transform->meta( key => "follows" );

        # XXX THIS BLOCK IS THE DUMBEST HACK EVER :(
        do {
            # enforce transform type ordering
            my @transform_type_order = qw/ cmdb_site subnet cmdb_profile cmdb_property cmdb_nodegroup group_role host /;
            unshift @transform_type_order, 'func'; # for unit tests asdlkjfeh
            my ( $tt ) = ( $transform =~ m{^($RE_CHISEL_transform_type)/} );

            confess "transform type '$tt' not recognized (used in $transform)"
              unless grep { $_ eq $tt } @transform_type_order;

            for my $tto (@transform_type_order) {
                last if $tto eq $tt;
                push @follows, "$tto/*";
            }
        };

        if( @follows ) {
            # @follows is going to be stuff like:
            #  - group_role/xxx.*
            #  - group_role/*

            # convert the globs in @follows to case-insensitive regexes
            my @follows_re = map { Text::Glob::glob_to_regex( lc $_ ) } @follows;

            # find all objects in @transforms that match
            foreach my $other_transform (@transforms) {
                # skip ourself
                next if $other_transform->id eq $transform->id;

                # add $other_transform if it matches anything from @follows_re
                push @{ $deps{$transform} }, $other_transform if grep { (lc $other_transform->name) =~ $_ } @follows_re;
            }
        }
    }

    # count the number of requirements per transform
    my %ndeps = map { $_ => scalar @{ $deps{$_} } } grep $deps{$_}, @transforms;

    # @sorted is our final list of sorted transforms
    my @sorted;

    # @free is a list of transforms that have no dependencies but aren't in @sorted yet
    # we're going to add transforms to @sorted by removing them from @free
    my @free = grep { ! $ndeps{$_} } @transforms;

    while( @free ) {
        # $free_min_t will be the lexicographically lowest transform
        # remove it from @free, add it to @sorted
        # this isn't the most efficient way to do it but whatever
        my $free_min_t;
        my $free_min_i;
        for( my $free_i = 0 ; $free_i < @free ; $free_i++ ) {
            if( !defined $free_min_t or lc $free[$free_i]->name lt lc $free_min_t->name ) {
                $free_min_t = $free[$free_i];
                $free_min_i = $free_i;
            }
        }

        splice @free, $free_min_i, 1;
        push @sorted, $free_min_t;

        foreach my $t (@transforms) { # bookkeeping
            # anything that depends on $free_min_t doesn't need to anymore
            if( grep { "$_" eq "$free_min_t" } @{ $deps{ $t } } ) {
                $ndeps{$t} --;

                # if $free_min_t was the last dependency for $t, add $t to @free
                if( ! $ndeps{$t} ) {
                    push @free, $t;
                }
            }
        }
    }

    if( @sorted != @transforms ) {
        my %transforms_lookup = map { $_->id => $_ } @transforms;

        confess(
            sprintf "Unable to resolve dependencies between transforms: %s",
                join( ", ", map { $transforms_lookup{$_}->name } grep { $ndeps{$_} } keys %ndeps )
        );
    }

    # add back DEFAULT, DEFAULT_TAIL as promised
    unshift @sorted, $has_default if $has_default;
    push @sorted, $has_default_tail if $has_default_tail;

    return @sorted;
}

# helper for '_parse'
# convert a full key-to-list map (like a transform as originally parsed from yaml)
# into a normalized transform
# %args:
#   - no_actions_check: don't enforce 'actions' restriction of module_conf
sub _normalize_transform {
    my ( $self, $rules_in, %args ) = @_;

    # ensure $rules_in is in an ok format
    if( ref $rules_in ne 'HASH' || grep { ref $_ ne 'ARRAY' } values %$rules_in ) {
        LOGDIE "$self: rules section is not a key-to-list yaml map";
    }

    # we're going to modify $rules_in during processing, so let's copy it unless we're told not to
    if( ! $args{'no_dclone'} ) {
        $rules_in = Storable::dclone( $rules_in );
    }

    # we'll normalize $rules_in to turn it into $rules_out
    # $rules_in might have keys like 'motd' or 'motd/MAIN', and might have macros or single-string actions
    # $rules_out only has keys like 'files/motd/MAIN', has no macros, and has 100% tokenized actions
    my $rules_out = {};

    # scan through each stanza of $rules_in; each is one key + its associated rule(s)
    # sort such that bare keys like "motd" always come before more-qualified keys like "motd/MAIN"
    while( my ( $key ) = sort { ( $a =~ tr!/!/! ) <=> ( $b =~ tr!/!/! ) or $a cmp $b } keys %$rules_in ) {

        # what fully-qualified keys (like files/motd/MAIN) does $key normalize into?
        my @keys_norm = $self->_normalize_key( $key );

        # what module is $key part of?
        my $module;

        if( $key =~ /^$RE_CHISEL_filepart\z/ ) {
            # $key is a bare key, like "motd"
            $module = $key;
        } else {
            # $key is a non-bare key, like "motd/MAIN", so look at @keys_norm
            ( $module ) = ( $keys_norm[0] =~ m!^$RE_CHISEL_filepart/($RE_CHISEL_filepart)! )
              or confess "Can't determine module for key [$key]";
        }

        # retrieve macros for this module
        # the && chain is to avoid autovivification
        my $macros =
          exists $self->{'module_conf'}{$module} && $self->{'module_conf'}{$module}{'macros'}
          ? $self->{'module_conf'}{$module}{'macros'}
          : {};

        # scan the rules for this key, searching for macros as well as regular actions
        foreach my $rule ( @{ $rules_in->{$key} } ) {
            if( $module eq $key and !ref $rule and $macros->{$rule} ) {
                # $rule refers to a macro; expand it into $rules_out

                # $macro is sort of like a mini-transform, so parse it recursively.
                my $macro = $self->_normalize_transform( $macros->{$rule}, no_actions_check => 1 );

                # now insert it into $rules_out
                push @{ $rules_out->{$_} }, @{ $macro->{$_} } for keys %$macro;
            } else {
                # $rule is not a macro; normalize the rules and insert them into $rules_out
                my $rule_norm = $self->_normalize_rule( $rule );

                # check if $rule's action is allowed
                if( !$args{'no_actions_check'} && !$self->_module_allows_action( $module, $rule_norm->[0] ) ) {
                    # this action is not allowed!
                    confess "'$rule_norm->[0]' not supported in '$key'";
                }

                # add the rules to $rules_out
                foreach my $key_norm ( @keys_norm ) {
                    # make sure the action is valid for the appropriate model
                    my $modelclass = $self->model( file => $key_norm );
                    my $action = $rule_norm->[0];
                    if( !$modelclass->can( "action_${action}" ) ) {
                        LOGCROAK "'$action' is not a valid action";
                    }

                    push @{ $rules_out->{$key_norm} }, $rule_norm;
                }
            }
        }

        # delete $key from $rules_in. it's been processed.
        delete $rules_in->{$key};
    }

    return $rules_out;
}

# helper for '_normalize_transform'
# convert a key like 'motd' or 'motd/MAIN' to 'files/motd/MAIN' (fully qualify it)
# may return multiple keys, e.g. in the case of default_file
# may die if the provided key is invalid
sub _normalize_key {
    my ( $self, $key ) = @_;

    # massage file names a little
    # we may turn this $key into one or more @newkeys (keys can multiply)
    # they eventually all need to match $RE_CHISEL_file
    my @newkeys;

    # if there are leading slashes..,
    if( $key =~ m{^/} ) {
        # strip them and assume the path does not need munging
        @newkeys = $key;
        $newkeys[0] =~ s{^/*}{};
    }

    # if there are no leading slashes and $key is a single file part...
    elsif( $key =~ /^$RE_CHISEL_filepart\z/ ) {
        # turn it into files/$key/@default_file
        # the && chains are to avoid autovivification
        my $default_file =
          exists $self->{'module_conf'}{$key} && $self->{module_conf}{$key}{'default_file'}
          ? $self->{module_conf}{$key}{'default_file'}
          : ['MAIN'];
        @newkeys = map { "files/$key/$_" } @$default_file;
    }

    # if there are no leading slashes and $key is two file parts...
    elsif( $key =~ m{^($RE_CHISEL_filepart)/($RE_CHISEL_filepart)$} ) {
        # let someone say scripts/whatever if they want. otherwise, turn $key = x/y into files/x/y
        @newkeys = $1 eq 'scripts' ? $key : "files/$key";
    }

    # otherwise just use $key as-is
    else {
        @newkeys = $key;
    }

    # check format post-munging
    foreach my $newkey ( @newkeys ) {
        # XXX the double check is to fix a problem where this match fails
        # XXX for no apparent reason when run under Devel::Cover :(
        if( $newkey !~ /^$RE_CHISEL_file\z/ && $newkey !~ /^$RE_CHISEL_file\z/ ) {
            confess( "'$key' is a bad file name" );
        }
    }

    return @newkeys;
}

# helper for '_normalize_transform'
# check if a particular module allows a certain action
sub _module_allows_action {
    my ( $self, $module, $action ) = @_;

    # the && chain is to avoid autovivification
    my $allowed_actions =
      exists $self->{'module_conf'}{$module} && $self->{'module_conf'}{$module}{'actions'}
      ? $self->{'module_conf'}{$module}{'actions'}
      : undef;

    if( $allowed_actions && !any { $_ eq $action } @$allowed_actions ) {
        # this action is not allowed!
        return;
    } else {
        # it's ok
        return 1;
    }
}

# helper for '_parse'
# take a rule like "append foo" and normalize it into [ "append", "foo" ]
# may die if the provided rule is invalid
sub _normalize_rule {
    my ( $self, $rule ) = @_;

    my ( $action, @rest );

    if( ref $rule eq 'ARRAY' && $rule->[0] && !ref $rule->[0] ) {
        # it's already in the form we want, sweet
        # just make sure everything we get is a string
        ( $action, @rest ) = map { "$_" } @$rule;
    } elsif( $rule =~ /^(\S+)(\s+(\S.*))?/ ) {
        # it can be a string like "append xxx"
        $action = $1;
        @rest = $3 if defined $3;
    } else {
        LOGDIE "Bad rule in $self";
    }

    # convert undef into empty string
    @rest = map { defined $_ ? $_ : '' } @rest;

    # actions expect no trailing newline
    chomp( @rest );

    return [ $action, @rest ];
}

sub DESTROY {
    my ( $self ) = @_;
    DEBUG "GC Transform [" . $self->id . "]";
}

1;
