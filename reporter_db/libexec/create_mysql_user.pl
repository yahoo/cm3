#!/bin/perl -w
######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


use warnings;
use strict;
use DBI;

if( defined( $ENV{reporter_db__rank} ) and $ENV{reporter_db__rank} eq "slave" ) {
    print "We're a slave database, exiting.\n";
    exit 0;
}


# connect with password
my $dbh = DBI->connect( 'DBI:mysql:host=localhost', 'root', 'foo', { RaiseError => 1 } );

# create chisel user
$dbh->do( "GRANT DELETE, INSERT, SELECT, UPDATE ON chisel.* TO 'chisel'\@'localhost' IDENTIFIED BY ?", undef, 'mysql' );

$dbh->disconnect;
