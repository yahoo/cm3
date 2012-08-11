######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Overmind::TransformSet;

use strict;

use Hash::Util ();
use Log::Log4perl qw/ :easy /;
use Scalar::Util qw/ blessed /;

use Chisel::Builder::Overmind::Metafile;
use Regexp::Chisel qw/ :all /;

sub new {
    my ( $class, %rest ) = @_;

    # @transforms -- contains one or more transform objects in unsorted order

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

    # confirm there is only one transform per name, case insensitively (name must be unique inside a transform set)
    my %transforms_uniq_index;
    LOGCROAK "Multiple transforms with the same name are not allowed"
      if grep { $transforms_uniq_index{ lc $_->name }++ } @transforms;

    # $id -- sort transforms alphabetically and join their IDs. used to compare TransformSets for equality

    my $id = $class->idfor( @transforms );

    # @transforms_ordered -- @transforms, ordered according to transform ordering rules.
    # if they're orderable, it also implies they're all is_good

    my $error_message;
    my @transforms_ordered;
    eval { @transforms_ordered = Chisel::Transform->order( @transforms ); }
      or do { $error_message = "TransformSet [$id] DOA: $@"; ERROR $error_message };

    # %metafile -- list of target files
    # use $rest{'mfsub'} to grab them (only if transforms are orderable/generateable)

    my %metafile;

    if( @transforms_ordered ) {

        # $_mftmp{ metafile name } = [ metafile transforms ]
        my %_mftmp;

        foreach my $transform ( @transforms_ordered ) {
            foreach my $file ( $transform->files ) {
                push @{ $_mftmp{$file} }, $transform;
            }
        }

        %metafile =
          map { $_ => $rest{'mfsub'}->( $_, @{ $_mftmp{$_} } ) }
          keys %_mftmp;
    }

    # Here's the object
    my $self = {
        # Globally unique identifier for this transform set
        id => $id,

        # List of transforms (ordered if possible, unordered otherwise)
        transforms => ( @transforms_ordered ? \@transforms_ordered : \@transforms ),

        # Is this transform set able to be generated (orderable + all is_good)?
        is_good => ( @transforms_ordered ? 1 : 0 ),

        # Bucket containing error message for this transformset
        error_bucket => ( @transforms_ordered ? undef : $rest{'ebsub'}->( $error_message ) ),

        # Table of target files
        metafile => \%metafile,

        # Does this transform set need (re-)packing?
        # Incremented one time for every reason this object needs packing
        needs_pack => 0,

        # hosts that point to this transformset
        # kept up-to-date by the Host class method
        hosts => {},
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

# see constructor for meanings
sub id           { shift->{id} }
sub is_good      { shift->{is_good} }
sub error_bucket { shift->{error_bucket} }
sub transforms   { @{ shift->{transforms} } }
sub metafiles    { values %{ shift->{metafile} } }

sub needs_pack {
    my ( $self, $needs_pack ) = @_;
    if( @_ > 1 ) {
        return $self->{needs_pack} = ( $needs_pack >= 0 ? $needs_pack : 0 );
    } else {
        return $self->{needs_pack};
    }
}

# unique identifier for some arbitrary transform set
# usually used statically like Chisel::Builder::Overmind::TransformSet->idfor( @transforms )
sub idfor {
    my ( $class, @transforms ) = @_;

    my $id = '';
    $id .= 't//' . ( blessed $_ ? $_->id : $_ )
      for sort { ( blessed $a ? $a->id : $a ) cmp( blessed $b ? $b->id : $b ) } @transforms;
    return $id;
}

# return hosts linked to this transformset
sub hosts {
    my ( $self ) = @_;
    return values %{ $self->{'hosts'} };
}

sub DESTROY {
    my ( $self ) = @_;
    DEBUG "GC TransformSet [$self->{id}]";
}

1;
