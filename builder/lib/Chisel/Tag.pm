######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Tag;

# objects of this class represent 'tag files' like the ones for a property
# they'll be called something like 'ops.us' and contain a yaml list of blobs

use warnings;
use strict;
use Chisel::Loadable;
use Log::Log4perl qw/:easy/;
use Regexp::Chisel qw/:all/;
use Text::Glob ();
use Scalar::Util ();
use YAML::XS ();
use Carp;

# print our name when used as a string
use overload '""' => sub { shift->{name} };

sub new {
    my ( $class, %rest ) = @_;

    my $defaults = {
        # these should be given upfront
        name         => '',
        yaml         => '',
    };

    my $self = { %$defaults, %rest };
    if( keys %$self > keys %$defaults ) {
        LOGDIE "Too many parameters, expected only " . join ", ", keys %$defaults;
    }

    # 'name' is required
    if( ! $self->{name} ) {
        LOGDIE "tag 'name' not given";
    }

    # check format of 'name'
    if( $self->{name} !~ /^$RE_CHISEL_tag\z/ ) {
        LOGDIE "tag 'name' is not well-formatted: $self->{name}";
    }

    # bless $self before making a copy of it
    bless $self, $class;

    # weaken a copy of $self so we don't end up creating a circular reference in the closure below
    my $weakself = $self;
    Scalar::Util::weaken($weakself);

    # lazy loading of the regex for this tag file
    $self->{_loadable} = Chisel::Loadable->new(
        loader => sub {
            # this will die if the YAML is bad
            my ( $globs ) = YAML::XS::Load( $weakself->{'yaml'} );

            # turn them into case-insensitive regexes
            # DEFAULT, DEFAULT_TAIL, host/hostname are always OK
            @$globs = map { Text::Glob::glob_to_regex_string( lc "$_" ) }
                ( 'DEFAULT', 'DEFAULT_TAIL', 'host/*', @$globs );

            # turn it into one big regex
            my $tag_re_string = '^(?:' . join( "|", @$globs ) . ')$';

            TRACE "Regex for tag $weakself is $tag_re_string";

            return qr/$tag_re_string/;
        }
    );

    # lock %$self to prevent typos
    Hash::Util::lock_keys(%$self);
    Hash::Util::lock_value(%$self, $_) for keys %$self;
    return $self;
}

sub match {
    my ( $self, @transforms ) = @_;
    my $tag_re = $self->{_loadable}->load;
    return grep { (lc $_->name) =~ $tag_re } @transforms;
}

# return the name of this tag, as a string
sub name {
    my ( $self ) = @_;
    return $self->{'name'};
}

# return the yaml of this tag, as a string
sub yaml {
    my ( $self ) = @_;
    return $self->{'yaml'};
}

1;

