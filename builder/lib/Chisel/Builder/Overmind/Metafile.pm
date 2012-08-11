######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Overmind::Metafile;

use strict;

use Hash::Util ();
use Scalar::Util qw/ blessed /;
use Log::Log4perl qw/ :easy /;

use Regexp::Chisel qw/ :all /;

use constant {
    # Completely new. Never even had needs_generate set.
    METAFILE_NEW => 100,

    # Never generated, but had needs_generate set once.
    METAFILE_PENDING => 200,

    # Generation attempt failed. Look in 'error_bucket' for message.
    METAFILE_ERR => 300,

    # Generation attempt was successful. Look in 'blob' for result.
    METAFILE_OK  => 400,
};

sub new {
    my ( $class, %rest ) = @_;

    # $name -- like "files/motd/MAIN" or "scripts/motd"

    my $name = $rest{'name'};

    if( $name !~ /^$RE_CHISEL_file\z/ ) {
        LOGCROAK "Invalid filename [$name]";
    }

    # @transforms -- ordered list of transforms that will generate this file

    my @transforms = @{ $rest{'transforms'} };

    if( !@transforms ) {
        LOGCROAK "No transforms";
    }

    if(
        my @bad_transforms =
        grep { !defined $_ or !blessed $_ or !$_->isa( "Chisel::Transform" ) } @transforms
      )
    {
        LOGCROAK "Invalid transforms [@bad_transforms]";
    }

    # @raw_needed -- raw files needed to generate this file

    my %raw_needed_dedupe = map { $_ => 1 } map { $_->raw_needed( file => $name ) } @transforms;
    my @raw_needed = keys %raw_needed_dedupe;

    # $id -- joined transforms IDs. used to compare Metafiles for equality

    my $id = $class->idfor( $name, @transforms );

    # Here's the object
    my $self = {
        # see above for these
        name       => $name,
        transforms => \@transforms,
        raw_needed => \@raw_needed,
        id         => $id,

        # NEW, PENDING, ERR, OK
        state => METAFILE_NEW,

        # blob sha
        # only look at this if state = OK
        # NOTE: blob undef + state OK => means skip this file (as if "unlink" action was used)
        blob => undef,

        # error bucket sha
        # only look at this if state = ERR
        error_bucket => undef,

        # does this file need (re-)generation?
        needs_generate => 0,
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

# see constructor for meanings
sub id         { shift->{id} }
sub name       { shift->{name} }
sub raw_needed { @{ shift->{raw_needed} } }
sub transforms { @{ shift->{transforms} } }

sub blob {
    my ( $self, $blob ) = @_;
    if( @_ > 1 ) {
        $self->{state} = METAFILE_OK;
        return $self->{blob} = $blob;
    } else {
        return $self->{blob};
    }
}

sub error_bucket {
    my ( $self, $error_bucket ) = @_;
    if( @_ > 1 ) {
        $self->{state} = METAFILE_ERR;
        return $self->{error_bucket} = $error_bucket;
    } else {
        return $self->{state} == METAFILE_ERR ? $self->{error_bucket} : undef;
    }
}

sub needs_generate {
    my ( $self, $needs_generate ) = @_;
    if( @_ > 1 ) {
        if( $self->{state} == METAFILE_NEW ) {
            $self->{state} = METAFILE_PENDING;
        }

        return $self->{needs_generate} = ( $needs_generate ? 1 : 0 );
    } else {
        return $self->{needs_generate};
    }
}

# true if and only if this metafile is "new" (never sent out for a generation attempt)
sub is_new {
    my ( $self ) = @_;
    return $self->{state} == METAFILE_NEW;
}

# true if and only if this metafile can be packed into a bucket
sub is_usable {
    my ( $self ) = @_;
    return $self->{state} == METAFILE_OK;
}

# unique identifier for some arbitrary transform set
# usually used statically like Chisel::Builder::Overmind::Metafile->idfor( $name, @transforms )
sub idfor {
    my ( $class, $name, @transforms ) = @_;

    my $id = 'f//' . $name;
    $id .= 't//' . ( blessed $_ ? $_->id : $_ ) for @transforms;
    return $id;
}

sub DESTROY {
    my ( $self ) = @_;
    DEBUG "GC Metafile [$self->{id}]";
}

1;
