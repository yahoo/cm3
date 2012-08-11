######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Raw::Roles;

use strict;
use warnings;
use base 'Chisel::Builder::Raw::Base';
use Log::Log4perl qw/ :easy /;
use Group::Client;

sub new {
    my ( $class, %rest ) = @_;

    my %defaults = (
        # Group::Client object
        c       => undef,
    );

    my $self = { %defaults, %rest };
    die "Too many parameters, expected only " . join ", ", keys %defaults
      if keys %$self > keys %defaults;

    # roles client
    if( !$self->{c} ) {
        LOGCROAK "Please pass in a Group::Client as 'c'";
    }

    # last_nonfatal_error is for the unit tests, to make sure various error
    # conditions are detected correctly
    $self->{last_nonfatal_error} = undef;

    bless $self, $class;
    Hash::Util::lock_keys(%$self);
    return $self;

}

sub fetch {
    my ( $self, $arg ) = @_;

    # clear last_nonfatal_error
    undef $self->{last_nonfatal_error};

    my @members;

    eval {
        @members = @{$self->{c}->role( $arg, "members" )->{members}};

        TRACE "Group_role: looked for $arg, got " . ( scalar @members ) . " members";
    };

    my $err = $@;

    if( $err && $err =~ /role '(.+)' does not exist/ ) {
        # roles error "role does not exist" just means this file was not found
        # so return undef
        $self->{last_nonfatal_error} = $err;
        return undef;
    } elsif( $err ) {
        # any other error, let's consider a real error (not file not found)
        die "$err\n";
    } else {
        # return roles result
        return join( "\n", sort @members ) . ( @members ? "\n" : "" );
    }
}

sub last_nonfatal_error { shift->{last_nonfatal_error} }

1;
