######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Engine::Actuate;

use 5.008;

use strict;
use warnings;
use Algorithm::Diff;
use Carp;
use Data::Dumper;
use Hash::Util ();
use SVN::Client;
use Socket;

sub new {
    my ( $class, %options ) = @_;

    my $self = {
        %options
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );

    $self->_setenv;

    return $self;
}

sub logger {
    Log::Log4perl->get_logger(__PACKAGE__);
}

sub svn_checkout {
  my ( $self ) = @_;

  my $checkout_rev; # the revision we got back from svn co

  my $rev = 'HEAD'; # don't ask for any particular revision
  my $recurs = 1;   # get subdirectories

  # define where our configuration repository is
  my $source = $self->{svn_url};

  # construct an svn client object
  $self->logger->info( "Begin checkout of $source to $self->{indir}" );
  my $ctx = new SVN::Client( config => SVN::Core::config_get_config( "/etc/subversion" ) );

  # svn revert our working copy of the repository
  if ( -d "$self->{indir}" && -f "$self->{indir}/.svn/entries" ) {
    $self->logger->debug( "sanitizing $self->{indir} : step 1 => svn revert" );
    $ctx->revert( $self->{indir} , 1 );

    # sanitize the working copy of any local changes
    $self->logger->debug( "sanitizing $self->{indir} : step 2 => clear unmanaged files" );
    my $status_handler = sub {
      my ( $path, $status ) = @_;
      if ( $status->text_status() == $SVN::Wc::Status::unversioned ) {
        $self->logger->debug( "unlinking unversioned node $path found in working directory" );
        if ( -f $path ) {
          unlink( $path )
            or $self->logger->debug( "unable to unlink unversioned file $path: $!" );
        } elsif ( -d $path && $path =~ /^\Q$self->{indir}\E\//) {
          system( "rm", "-rf", $path ) == 0
            or $self->logger->debug( "unable to remove unversioned directory $path: $!" );
        }
      }
    };
    $ctx->status ( $self->{indir},
                   $rev,
                   $status_handler,
                   $recurs, 0, 0, 0,
                 );
  }

  # check the configuration out from the repository
  $checkout_rev = $ctx->checkout ( $source,
                                   $self->{indir},
                                   $rev,
                                   $recurs,
                                 );
  $self->logger->info( "Check out of revision $checkout_rev succeeded." );

  return $checkout_rev;
}

sub _setenv {
  my $self = shift;
  $ENV{'SVN_SSH'} = "ssh -o UserKnownHostsFile=$self->{ssh_known_hosts} -o BatchMode=yes -i $self->{ssh_identity}";
}

sub indir {
    my ( $self ) = @_;
    return $self->{indir};
}

sub libexec {
  my ( $self, @cmdline ) = @_;

  $self->logger->info( "starting command $cmdline[0]" );
  system(@cmdline) == 0
    or croak "$cmdline[0] failed with code $?:$!";
  $self->logger->info( "external command $cmdline[0] completed successfully" );
  return $cmdline[0];
}

sub acquire_lock {
  my $port = 11533;
  my $proto = getprotobyname('tcp');
  socket(Server, PF_INET, SOCK_STREAM, $proto) or return undef;
  bind(Server, sockaddr_in($port, INADDR_ANY)) or return undef;
  1;
}

1;
