######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::Sudoers;

use strict;

use base 'Chisel::TransformModel::Text';

sub action_add {
    my ( $self, @args ) = @_;
    return $self->action_append( map { "$_ ALL = (ALL) ALL" } map { split /\s*,\s*/ } @args );
}

1;
