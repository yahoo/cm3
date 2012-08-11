######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::Text;

use strict;

use base 'Chisel::TransformModel';

use List::MoreUtils qw/any/;

sub new {
    my ( $class, %args ) = @_;
    $class->SUPER::new(
        ctx      => $args{'ctx'},
        contents => $args{'contents'},
        text     => '',
    );
}

sub text {
    my ( $self ) = @_;
    return $self->{'text'};
}

# prepend to file, with trailing newline
sub action_prepend {
    my ( $self, @args ) = @_;
    @args = ( '' ) if !@args;    # if no @args provided, use a single blank line
    $self->{'text'} = "$_\n$self->{text}" for @args;
    return 1;
}

# append unless already there, with trailing newline
sub action_appendunique {
    my ( $self, @args ) = @_;
    @args = ( '' ) if !@args;    # if no @args provided, use a single blank line
    foreach my $arg ( @args ) {
        $self->{'text'} = "$self->{text}$arg\n" if !grep { $_ eq "$arg\n" } split /^/m, $self->{'text'};
    }
    return 1;
}

# append with no trailing newlines
sub action_appendexact {
    my ( $self, @args ) = @_;
    $self->{'text'} = "$self->{text}$_" for @args;
    return 1;
}

# remove a line that *is* $arg or *starts with* $arg:
# XXX might be better to make this smarter and move it into various models
# XXX (taking it out of the Text model)
sub action_remove {
    my ( $self, @args ) = @_;

    @args = map { split /\s*,\s*/ } @args;

    foreach my $arg ( @args ) {
        $self->{'text'} = join '', grep { !/^$arg(\:|$)/ } split /^/m, $self->{'text'};
    }

    return 1;
}

# delete a verbatim line
sub action_delete {
    my ( $self, $arg ) = @_;
    $self->{'text'} = join '', grep { $_ ne "$arg\n" } split /^/m, $self->{'text'};
    return 1;
}

# delete lines that match a regex
sub action_deletere {
    my ( $self, $arg ) = @_;

    no re 'eval';    # just in case
    $self->{'text'} = join '', grep { not /$arg/ } split /^/m, $self->{'text'};
    return 1;
}

# start from scratch
sub action_truncate {
    my ( $self ) = @_;
    $self->{'text'} = '';
    return 1;
}

sub action_dedupe {
    my ( $self ) = @_;
    my %seen;
    $self->{'text'} = join "", grep { !( $seen{$_}++ ) } split /^/m, $self->{'text'};
    return 1;
}

# replacere helper (see base class for info)
sub _replacere {
    my ( $self, $replace, $with ) = @_;

    # just in case
    no re 'eval';

    # this eval will make us appropriately follow the action spec (1 = good, undef = error)
    return eval q!$self->{text} = join "", map { s/$replace/! . $with . q!/g; "$_\n"; } split /\n/m, $self->{text}; 1;!;
}

1;
