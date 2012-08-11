######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::Builder::Engine;

use strict;

use Digest::MD5 ();
use Fcntl qw/:DEFAULT :flock/;
use Hash::Util ();
use IO::Socket::INET;
use Log::Log4perl qw/:easy/;
use Net::ZooKeeper;
use Sys::Hostname ();
use YAML::XS ();
use Chisel::Builder::Engine::Actuate;
use Chisel::Builder::Engine::Checkout;
use Chisel::Builder::Engine::Generator;
use Chisel::Builder::Engine::Packer;
use Chisel::Builder::Engine::Walrus;
use Chisel::Builder::ZooKeeper::Leader;
use Chisel::Builder::ZooKeeper::Worker;
use Chisel::Metrics;
use Regexp::Chisel qw/:all/;

sub new {
    my ( $class, %userconfig ) = @_;

    my $self = {
        configfile => ( delete $userconfig{'configfile'} || "/conf/builder.conf" ),
        application      => undef,    # application to use for metrics
        metrics          => undef,    # undef means fill it when asked
        config           => undef,    # undef means load from 'configfile'
        is_setup         => undef,    # have we had ->setup called yet?
        keydb_init       => undef,    # have we called ycrKeyDbInit yet?
        userconfig       => undef,    # overlay on top of 'config'
    };

    $self->{'userconfig'} = \%userconfig;

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

# basic setup:
#   - make sure we're not running as root
#   - read config file
#   - init Log4perl
sub setup {
    my ( $self, %args ) = @_;

    # return if we already are setup
    return if $self->is_setup;

    if(!$args{'root_ok'} && $< == 0) {
        die "please do not run this as root\n";
    }

    my $l4p_level   = $self->config( "log4perl_level" );
    my $l4p_pattern = $self->config( "log4perl_pattern" );
    my $l4p_config  = <<EOT;
log4perl.rootLogger =                                 $l4p_level, stderr
log4perl.logger.Group.Roles =                         WARN, stderr
log4perl.logger.Net.SSH =                             WARN, stderr
log4perl.appender.stderr =                            Log::Log4perl::Appender::Screen
log4perl.appender.stderr.layout =                     PatternLayout
log4perl.appender.stderr.layout.ConversionPattern =   $l4p_pattern
log4perl.appender.stderr.stderr =                     1
EOT

    Log::Log4perl->init( \$l4p_config );

    # set is_setup so we know this all happened
    $self->{is_setup} = 1;

    # return $self for chaining
    return $self;
}

# has ->setup been called yet?
sub is_setup {
    my ( $self ) = @_;
    return $self->{is_setup};
}

# flock a particular file (the "keyword"), and return a handle to it
sub lock {
    my ( $self, $keyword, %args ) = @_;

    my $lockfd;
    my $lockdir = $self->config( "var" ) . "/lock";

    my $lockp = "$lockdir/$keyword";
    sysopen $lockfd, $lockp, O_WRONLY | O_CREAT
      or LOGCROAK "open $lockp: $!";

    # allow block => 1 to wait for ability to lock
    my $flags = $args{'block'} ? LOCK_EX : LOCK_EX | LOCK_NB;

    flock $lockfd, $flags
      or LOGCROAK "lock $lockp: $!";
    return $lockfd;
}

# return handle to metrics object
# there is only ONE of these
sub metrics {
    my ( $self ) = @_;

    $self->{metrics} ||= Chisel::Metrics->new(
        application => $self->config( 'application' ),

    );

    return $self->{metrics};
}

# Stubbed for now. CMDB::Client does not exist.
# return handle to cmdb client object
# there can be MORE THAN ONE of these
sub cmbddb {
    my ( $self, %args ) = @_;

    my $cmdb = CMDB::Client->new(
        host => $self->config( "cmdb_url" ),
        user => $self->config( "cmdb_user" ),
        pass => $self->config( "cmdb_pass" ),
        %args,
    );

    return $cmdb;
}

# Stubbed for now. Group::Client does not exist
# return handle to roles client object
# there can be MORE THAN ONE of these
sub roles {
    my ( $self, %args ) = @_;

    my $roles = Group::Client->new(
        baseuri => $self->config( "group_url" ) || undef,    # turn '' into undef
        %args,
    );

    return $roles;
}

# return an Actuate engine
# there can be MORE THAN ONE of these so save a reference if you need it
sub new_actuate {
    my ( $self, %args ) = @_;

    # default location for various important directories
    my $var = $self->config( "var" );
    $args{'indir'}    ||= "$var/indir";

    # fill in some parameters from our configuration, if they aren't overridden by the caller
    $args{$_} = $self->config( $_ ) for grep { !exists $args{$_} } qw/ svn_url
      ssh_user
      ssh_identity
      ssh_known_hosts /;

    # pass in our shared metrics object
    $args{'metrics_obj'} ||= $self->metrics;

    return Chisel::Builder::Engine::Actuate->new( %args );
}

# return a Checkout engine
# there can be MORE THAN ONE of these so save a reference if you need it
sub new_checkout {
    my ( $self, %args ) = @_;

    # default location for various important directories
    my $var = $self->config( "var" );
    $args{'transformdir'} ||= "$var/indir/transforms";
    $args{'tagdir'}       ||= "$var/indir/tags";
    $args{'scriptdir'}    ||= "$var/modules";

    if( !exists $args{'rawobj'} ) {
        # delete $args{'rawdir'} since it's not actually going to be passed to a Checkout object
        # we're deleting it inside this conditional so 'rawdir' and 'rawobj' conflict with each other (as they should)
        my $rawdir = delete $args{'rawdir'} || "$var/indir/raw";

        # set up the dynamic raw filesystem
        my $r           = Chisel::Builder::Raw->new;
        my $r_fs        = Chisel::Builder::Raw::Filesystem->new( rawdir => $rawdir, );
        my $r_roles     = Chisel::Builder::Raw::Roles->new( c => $self->roles );
        my $r_usergroup = Chisel::Builder::Raw::UserGroup->new( c => $self->cmdb, );
        
        my $r_hostlist = Chisel::Builder::Raw::HostList->new(
            group_client => $self->roles,
            range_tag    => $self->config( 'range_tag' ),
            maxchange    => $self->config( 'range_maxchange' ),
            cache_file   => $self->config( "var" ) . "/cache/hostlist-sqlite",
        );

        # for reading files directly out of svn
        $r->mount( plugin => $r_fs, mountpoint => "/" );

        # XXX sort of a hack to treat module scripts as raw files
        # XXX and to allow modules to bundle arbitrary files
        foreach my $module ( glob "$args{scriptdir}/*" ) {
            $module =~ s{^.*/([^/]+)$}{$1};
            next unless $module;

            my $module_script_fs =
              Chisel::Builder::Raw::Filesystem->new( rawdir => "$args{scriptdir}/$module/scripts" );
            my $module_file_fs =
              Chisel::Builder::Raw::Filesystem->new( rawdir => "$args{scriptdir}/$module/files" );

            $r->mount( plugin => $module_script_fs, mountpoint => "/modules/$module" );
            $r->mount( plugin => $module_file_fs,   mountpoint => "/${module}.bundle" );
        }

        # virtual mountpoints for roles and cmdb usergroups, used for invokefor
        $r->mount( plugin => $r_roles, mountpoint => "/group_role" );
        $r->mount( plugin => $r_usergroup, mountpoint => "/cmdb_usergroup" );

        # virtual mountpoints for magically imported raw files
        $r->mount( plugin => $r_hostlist,  mountpoint => "/internal/hostlist" );

        $args{'rawobj'} = $r;
    }

    # pass in our shared metrics object
    $args{'metrics_obj'} ||= $self->metrics;

    return Chisel::Builder::Engine::Checkout->new( %args );
}

sub new_walrus {
    my ( $self, %args ) = @_;

    if( !exists $args{'transforms'} ) {
        LOGCROAK "please pass in transforms";
    }

    if( !exists $args{'tags'} ) {
        LOGCROAK "please pass in tags";
    }

    if( !exists $args{'groupobj'} ) {
        # this is what the walrus will use to assign transforms and tags to hosts
        my $g       = Chisel::Builder::Group->new;
        my $g_host  = Chisel::Builder::Group::Host->new;
        my $g_roles = Chisel::Builder::Group::Roles->new(
            c          => $self->roles,
            threads    => $self->config( "roles_threads" ),
            cache_file => $self->config( "var" ) . "/cache/roles-sqlite",
            turbo      => $self->config( "roles_turbo" ),
        );
        my $g_cmdb_node = Chisel::Builder::Group::cmdbNode->new(
            c          => $self->cmdb,
            cache_file => ( $self->config( "var" ) . "/cache/cmdb-sqlite" ),
            turbo      => $self->config( "cmdb_turbo" ),
        );

        $g->register( plugin => $g_host );
        $g->register( plugin => $g_roles );
        $g->register( plugin => $g_cmdb_node );
        $g->register( plugin => $g_cmdb_nodegroup );

        $args{'groupobj'} = $g;
    }

    if( !exists $args{'require_group'} ) {

        # require_group can prevent inconsistencies in roles api calls from causing problems
        WARN "new_walrus: Consider using 'require_group' as a safety measure";
    }

    # fill in some parameters from our configuration, if they aren't overridden by the caller
    $args{$_} = $self->config( $_ ) for grep { !exists $args{$_} } qw/ require_tag /;

    # pass in our shared metrics object
    $args{'metrics_obj'} ||= $self->metrics;

    return Chisel::Builder::Engine::Walrus->new( %args );
}

sub new_generator {
    my ( $self, %args ) = @_;

    # default location for various important directories
    $args{'workspace'} ||= $self->config( "var" ) . "/ws";

    return Chisel::Builder::Engine::Generator->new( %args );
}

sub new_packer {
    my ( $self, %args ) = @_;

    # default location for various important directories
    $args{'workspace'} ||= $self->config( "var" ) . "/ws";
    $args{'gnupghome'} ||= $self->config( "gnupghome" );

    # 'sanity_socket' will be established unless passed in (it can be passed in undef to omit this)
    if( !exists $args{'sanity_socket'} ) {
        # delete $args{'sanity_server'} and $args{'sanity_port'} since it's not actually going to be passed to a Generator object
        my $host = delete $args{'sanity_server'} || $self->config( "sanity_server" ) || "localhost";
        my $port = delete $args{'sanity_port'}   || $self->config( "sanity_port" ) || 10001;

        $args{'sanity_socket'} = IO::Socket::INET->new(
            PeerAddr => $host,
            PeerPort => $port,
            Proto    => 'tcp',
        ) or die "Can't create a socket to Sanity server ($host:$port): $!\n";
    }

    return Chisel::Builder::Engine::Packer->new( %args );
}

sub new_workspace {
    my ( $self, %args ) = @_;
    return Chisel::Workspace->new( dir => $self->config( "var" ) . "/ws", %args );
}

# return handle to ZooKeeper leader object
sub new_zookeeper_leader {
    my ( $self ) = @_;

    return Chisel::Builder::ZooKeeper::Leader->new(
        connect    => $self->config("zookeeper_connect"),
        redundancy => $self->config("cluster_redundancy"),
        cluster    => [ split ';', $self->config("cluster") ],
    );
}

# return handle to ZooKeeper worker object
# there is only ONE of these
sub new_zookeeper_worker {
    my ( $self, $worker ) = @_;

    if( !$worker ) {
        # Default worker name is our hostname
        $worker = Sys::Hostname::hostname();
    }

    return Chisel::Builder::ZooKeeper::Worker->new( connect => $self->config("zookeeper_connect"), worker => $worker );
}

# read a key out of our config file
sub config {
    my ( $self, $key, $opts ) = @_;

    if( !defined $self->{config} ) {
        # this dies on failure, that's ok
        my $config = YAML::XS::LoadFile( $self->{configfile} );

        # overlay the userconfig
        %$config = ( %$config, %{ $self->{'userconfig'} } );

        # save our config
        $self->{config} = $config;
    }

    # config is loaded, just return whatever was asked for
    if( exists $self->{config}{$key} ) {

        # return the value, whether or not it came from keydb

        return $self->{config}{$key};
    } else {
        # err, what
        # settings should always be available in the conf file even if they're undef
        # this probably means whatever code called ->config has a typo in it, let's die as a safeguard

        # need to use die because log4perl may not be inited yet
        die "setting '$key' does not seem to exist\n";
    }
}

# Scrubs possibly sensitive strings from error messages.
sub scrub_error {
    my ( $self, $message ) = @_;

    $message =~ s/at .+ line \d+.*//sg;                           # remove stack traces
    $message =~ s/\$\d\$[a-zA-Z0-9\.\/\$]{8,}/XXXXXXXXXXXX/sg;    # just in case
    $message =~ s/\s+\z//g;                                       # remove trailing whitespace

    return $message;
}

1;
