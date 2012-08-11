######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Raw::Base;

# Chisel::Builder::Raw::Base subclasses represent some *type* (or, sometimes,
# *types*) of data that can be stored in and accessed through the Chisel raw file
# system. Each type of raw file is normally mounted in a particular directory of
# the raw file system.
#
# Subclasses can define more than one type of data. This is useful if multiple
# types of data can be fetched and cached at the same time, in which case this
# is handled transparently by the subclass (example: cmdb site and property).
#
# Traditionally the / mount point is the raw/ directory from svn.

use strict;
use Log::Log4perl qw/:easy/;
use Hash::Util ();

# Expiration time -- zero means don't use expirations, just always re-fetch
sub expiration { return 0; }

# input: name of file relative to this plugin
# output: contents of file as a string
sub fetch { LOGDIE "unimplemented"; }

# input: (1) contents of old file, (2) contents of new file
# output: true or false
sub validate { return 1; }

1;
