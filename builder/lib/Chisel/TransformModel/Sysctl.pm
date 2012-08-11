######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::Sysctl;

use strict;

use base 'Chisel::TransformModel::Text';

sub action_set {
    my ( $self, @args ) = @_;

    foreach my $arg ( @args ) {
        chomp $arg;
        my ( $key, $value ) = ( $arg =~ /^([^=\s]+)\s*=\s*(.+)$/ )
          or die "sysctl: invalid sysctl [$arg]";

        # Try replace first
        if( not $self->{'text'} =~ s/^\Q$key\E\s*=\s*.+$/$arg/m ) {
            # Replace did not work, just append
            $self->{'text'} .= "$arg\n";
        }
    }

    return 1;
}

1;
