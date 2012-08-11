######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::Passwd;

use strict;

use base 'Chisel::TransformModel::PasswdLike';

use Regexp::Chisel qw/:all/;

sub raw_needed {
    my ( $self, $action, @rest ) = @_;

    my @needed;

    if( $action eq 'give_me_all_users' ) {
        push @needed, $self->_rawsrc;
    } else {
        push @needed, $self->SUPER::raw_needed( $action, @rest );
    }

    return @needed;
}

# internal methods used by our base class
sub _rawsrc     { return 'passwd' }
sub _nameregexp { return $RE_CHISEL_username }

# change a user's shell
sub action_chsh {
    my ( $self, @args ) = @_;

    my ( $user, $shell );

    if( !@args ) {
        # args are required
        return undef;
    } elsif( @args <= 1 ) {
        # assume we got a single string
        my $line = $args[0] || '';
        ( $user, $shell ) = ( $args[0] =~ /^(\S+)\s+(.*)$/ );
    } else {
        ( $user, $shell ) = @args;
    }

    if( !$user || !$shell ) {
        return undef;
    }

    # make sure shell has at least a semi-sane format
    if( $shell !~ m{^(/\w+)+$} ) {
        return undef;
    }

    # change the shell
    if( $self->{'rows'}{$user} ) {
        $self->{'rows'}{$user}{'text'} =~ s/:[^:]*$/:$shell/;
    }

    return 1;
}

# what "add *" would do if that worked
sub action_give_me_all_users {
    my ( $self, $shell_override ) = @_;

    if( $shell_override && $shell_override =~ /^shell=(\S+)$/ ) {
        $shell_override = $1;
    } elsif( $shell_override ) {
        # bad shell override
        return undef;
    }

    # first read all names and ids in the current $self->{rows}
    my %current_names;
    my %current_ids;

    foreach my $row ( values %{ $self->{'rows'} } ) {
        $current_names{ $row->{'name'} } = 1;
        $current_ids{ $row->{'id'} }     = 1;
    }

    # now add any missing users
    my $map = $self->_map;

    foreach my $maprow ( values %$map ) {
        next
          if $current_names{ $maprow->{'name'} }    # skip names we already have
              || $current_ids{ $maprow->{'id'} }    # skip ids we already have
              || $maprow->{'id'} < 1000             # skip low ids
              || $maprow->{'id'} >= 2**32 - 2;      # skip high ids

        my $text = $maprow->{'text'};

        if( $shell_override ) {
            $text =~ s/:([^:]*)$/:$shell_override/;
        }

        $self->_addrow( { text => $text, name => $maprow->{'name'}, id => $maprow->{'id'} } );
    }

    return 1;
}

1;
