######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Raw::Hash;

use strict;
use warnings;
use base 'Chisel::Builder::Raw::Base';
use Log::Log4perl qw/ :easy /;

sub new {
    my ( $class, %rest ) = @_;

    my %defaults = ( hash => undef, );

    my $self = { %defaults, %rest };
    die "Too many parameters, expected only " . join ", ", keys %defaults
      if keys %$self > keys %defaults;

    # strip leading slashes in hash keys
    my %hash;

    foreach my $k (keys %{$self->{hash}}) {
        my $kstripped = $k;
        $kstripped =~ s{^/*}{};

        if( exists $hash{$kstripped} ) {
            LOGDIE "cannot have multiple files named $kstripped";
        } else {
            $hash{$kstripped} = $self->{hash}{$k};
        }
    }

    # overwrite $self->{hash} with the fixed one
    $self->{hash} = \%hash;

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

# Read a file, store it as a string in $self->{rawcache}{$filename}
sub fetch {
    my ( $self, $arg ) = @_;

    if( defined $self->{hash}{$arg} ) {
        return $self->{hash}{$arg};
    } else {
        ERROR "$arg does not exist\n";
        return undef;
    }
}

1;
