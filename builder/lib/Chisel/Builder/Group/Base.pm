######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Group::Base;

# Chisel::Builder::Group::Base subclasses represent some host grouping
# mechanism. Each one has a name and the groups are prefixed by that name.

use strict;
use Log::Log4perl qw/:easy/;

# Must be called before the first fetch. Allows Group subclasses to perform
# any needed setup actions (updating a local cache is common).
#
# Called as: 
# $obj->setup(
#    hosts_cb => sub { return [h1, h2, ...] },
#    groups_cb => sub { return [g1, g2, ...] } )
#
# The callbacks will not necessarily be used. It depends on the subclass.
sub setup { return 1; }

# List of group types supported by this subclass.
sub impl { return (); }

# Called as:
# $obj->fetch(
#    hosts => [h1, h2, ...],
#    groups => [g1, g2, ...],
#    cb => sub { called with host, groups } )
#
# The callback may be called multiple times per host.
sub fetch { LOGDIE "unimplemented"; }

1;
