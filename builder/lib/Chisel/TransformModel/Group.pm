######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::Group;

use strict;

use base 'Chisel::TransformModel::PasswdLike';

use Regexp::Chisel qw/:all/;

sub raw_needed {
    my ( $self, $action, @rest ) = @_;

    my @needed;

    if( $action eq 'give_me_all_groups' ) {
        push @needed, $self->_rawsrc;
    } else {
        push @needed, $self->SUPER::raw_needed( $action, @rest );
    }

    return @needed;
}

# internal methods used by our base class
sub _rawsrc     { return 'group' }
sub _nameregexp { return $RE_CHISEL_groupname }

sub _merge {
    my ( $self, $rowa, $rowb ) = @_;

    # new text will go here
    my $newtext = $rowa->{text};

    # split rowa into prefix (groupname:*:gid:) and users (root,foo,bar)
    my ( $rowa_users_text ) = ( $rowa->{text} =~ /:([^:]*)$/ );

    # lookup table for users in rowa
    my %usersa =
      defined $rowa_users_text
      ? map { $_ => 1 } split /,/, $rowa_users_text
      : ();

    # extract users from rowb
    my ( $rowb_users_text ) = ( $rowb->{text} =~ /:([^:]*)$/ );
    my @usersb = defined $rowb_users_text ? split /,/, $rowb_users_text : ();

    # add users from rowb to rowa
    my $first_user_add = %usersa ? 0 : 1;
    foreach my $userb ( @usersb ) {
        if( !$usersa{$userb} ) {
            $newtext .= ( $first_user_add ? '' : ',' ) . $userb;
            $first_user_add = 0;
        }
    }

    # return new text
    return $newtext;
}

# what "add *" would do if that worked
sub action_give_me_all_groups {
    my ( $self, @args ) = @_;

    # first read all ids in the current $self->{rows}
    my %row_name_by_id;

    foreach my $row ( values %{ $self->{'rows'} } ) {
        $row_name_by_id{ $row->{'id'} } = $row->{'name'};
    }

    # now add any missing names
    my $map = $self->_map;

    foreach my $maprow ( values %$map ) {
        next
          if(  $row_name_by_id{ $maprow->{'id'} }
            && $row_name_by_id{ $maprow->{'id'} } ne
            $maprow->{'name'} )    # skip ids we already have, if the name is different
          || $maprow->{'id'} < 1000           # skip low ids
          || $maprow->{'id'} >= 2**32 - 2;    # skip high ids

        my $text = $maprow->{'text'};

        $self->_addrow( { text => $text, name => $maprow->{'name'}, id => $maprow->{'id'} } );
    }

    return 1;
}

1;
