######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::CheckoutPack::Staged;

use strict;
use warnings;

use Fcntl;
use File::Temp ();
use Hash::Util ();
use Log::Log4perl qw/:easy/;
use YAML::XS ();

use Chisel::RawFile;
use Chisel::Transform;

sub new {
    my ( $class, %rest ) = @_;

    my $self = {};

    # Create temporary directory
    $self->{tmp} = File::Temp->newdir( CLEANUP => 1 );
    $self->{stagedir} = $self->{tmp}->dirname;

    # Placeholders for indexes
    $self->{raw_index}   = undef;
    $self->{hosts_index} = undef;

    bless $self, $class;
    Hash::Util::lock_keys( %$self );
    return $self;
}

sub stagedir {
    my ( $self ) = @_;
    return $self->{stagedir};
}

# Return pack-wide version number
sub version {
    my ( $self ) = @_;
    if( -f "$self->{stagedir}/version" ) {
        return $self->_read_file( 'version' );
    } else {
        return undef;
    }
}

# Return blob for one raw file (only needs index, not disk... it's faster)
sub raw_blob {
    my ( $self, $name ) = @_;
    my $index = $self->_raw_index;
    return $index->{$name} && $index->{$name}{blob};
}

# Read one raw file
# Returns undef if this raw file does not exist
sub raw {
    my ( $self, $name ) = @_;

    my $index = $self->_raw_index;

    if( !$index->{$name} ) {
        return undef;
    }

    my $blob         = $index->{$name}{blob};
    my $blob_pending = $index->{$name}{blob_pending};
    my $ts           = $index->{$name}{ts};

    my $data         = defined $blob         ? $self->_read_file( "obj/$blob" )         : undef;
    my $data_pending = defined $blob_pending ? $self->_read_file( "obj/$blob_pending" ) : undef;

    my $raw = Chisel::RawFile->new(
        name         => $name,
        data         => $data,
        data_pending => $data_pending,
        ts           => $ts,
    );

    # Sanity check on raw blob
    if( $blob and $raw->blob ne $blob ) {
        LOGDIE "Object [$blob] appears corrupt!";
    }

    return $raw;
}

# Return transform IDs for a particular host
sub host_transforms {
    my ( $self, $host ) = @_;

    my $index = $self->_hosts_index;
    if( $index->{$host} ) {
        return @{ $index->{$host} };
    } else {
        return ();
    }
}

# Return transform object for a transform ID
sub transform {
    my ( $self, $transform_id ) = @_;

    my ( $transform_name, $transform_blob ) = $transform_id =~ /(.*)\@([a-f0-9]{40})\z/
      or LOGDIE "Invalid transform id [$transform_id]";

    my $transform_yaml = $self->_read_file( "obj/$transform_blob" );
    my $transform_obj = Chisel::Transform->new( name => $transform_name, yaml => $transform_yaml );

    # Sanity check on transform blob
    if( $transform_obj->yamlblob ne $transform_blob ) {
        LOGDIE "Object [$transform_blob] appears corrupt!";
    }

    return $transform_obj;
}

# Review one raw file (move data_pending -> data)
sub review_raw {
    my ( $self, $raw_obj ) = @_;

    my $index = $self->_raw_index;
    my $name  = $raw_obj->name;
    if(
            $index->{$name}
        and defined $index->{$name}{blob_pending}
        and defined $raw_obj->blob_pending
        and $index->{$name}{blob_pending} eq $raw_obj->blob_pending
        and ( !defined $index->{$name}{blob} && !defined $raw_obj->blob
            or defined $index->{$name}{blob} && defined $raw_obj->blob && $index->{$name}{blob} eq $raw_obj->blob )
      )
    {
        # blob_pending looks OK, let's copy it in
        eval {
            delete $index->{$name}{blob_pending};
            $index->{$name}{blob} = $raw_obj->blob_pending;
            $self->_write_file( "obj/" . $raw_obj->blob_pending, $raw_obj->data_pending );
            $self->_write_file( "raw.idx",                       YAML::XS::Dump( $index ) );
        };

        if( $@ ) {
            # Clear index so it is regenerated.
            # It might be inconsistent as a result of the exception.
            undef $self->{raw_index};

            # Re-die
            LOGDIE $@;
        }

        return 1;
    } else {
        LOGDIE "Raw file [$name] cannot be set to [" . ( $raw_obj->blob_pending // 'undef' ) . "]";
    }
}

# Smash current directory with new:
#  host_transforms: host -> transform map
#  raws: raw file array
# XXX - would be nice to have a checksum of some kind
sub smash {
    my ( $self, %args ) = @_;

    # Clear in-memory indexes
    $self->{raw_index}   = undef;
    $self->{hosts_index} = undef;

    # Rename for convenience
    my $stagedir        = $self->{'stagedir'};
    my $host_transforms = $args{'host_transforms'};
    my $raws            = $args{'raws'};

    # This will eventually become raw.idx
    my %raw_index;

    # This will eventually become hosts.idx
    my %hosts_index;

    # Assign each arrayref in $host_transforms to an arrayref for hosts.idx
    my %transforms_converted;

    # Keep track of whether an object in obj/ has been created yet
    my %obj_exists;

    # Create obj/ directory if not already there
    if( !-d "$stagedir/obj" ) {
        mkdir "$stagedir/obj" or LOGDIE "mkdir $stagedir/obj: $!";
    }

    DEBUG "Writing transforms to $stagedir/obj/";
    while( my ( $host, $transforms ) = each( %$host_transforms ) ) {
        if( !$transforms_converted{ $transforms + 0 } ) {
            $transforms_converted{ $transforms + 0 } = [ map { $_->id } @$transforms ];

            for my $transform ( @$transforms ) {
                if( !$obj_exists{ $transform->yamlblob } ) {
                    $obj_exists{ $transform->yamlblob } = 1;
                    $self->_write_file( "obj/" . $transform->yamlblob, $transform->yaml );
                }
            }
        }

        $hosts_index{$host} = $transforms_converted{ $transforms + 0 };
    }

    DEBUG "Writing raw files to $stagedir/obj/";
    for my $raw ( @$raws ) {
        $raw_index{ $raw->name }{ts} = $raw->ts;

        for my $fsuffix ( '', '_pending' ) {
            my $fblob = 'blob' . $fsuffix;
            my $fdata = 'data' . $fsuffix;

            if( defined $raw->$fdata ) {
                my $data = $raw->$fdata;
                my $blob = $raw->$fblob;

                $raw_index{ $raw->name }{$fblob} = $blob;
                $obj_exists{$blob} = 1;
                $self->_write_file( "obj/$blob", $data );
            }
        }
    }

    # Update version number
    # XXX should include REPO too
    DEBUG "Writing serial number to $stagedir/version";
    $self->_write_file( "version", time . "\n" );

    DEBUG "Writing raw file index to $stagedir/raw.idx";
    $self->_write_file( "raw.idx", YAML::XS::Dump( \%raw_index ) );

    DEBUG "Writing host -> transforms index to $stagedir/hosts.idx";
    $self->_write_file( "hosts.idx", YAML::XS::Dump( \%hosts_index ) );

    DEBUG "Removing stale objects from $stagedir/obj/";
    for my $obj_path ( glob "$stagedir/obj/*" ) {
        my ( $obj_id ) = ( $obj_path =~ m!/([^/]+)$! );
        if( !$obj_exists{$obj_id} ) {
            unlink $obj_path or LOGDIE "unlink $obj_path: $!";
        }
    }

    return;
}

sub _read_file {
    my ( $self, $name ) = @_;

    open my $fh, "$self->{stagedir}/$name" or LOGDIE "open $self->{stagedir}/$name: $!";
    my $contents = do { local $/; <$fh> };
    close $fh or LOGDIE "close $self->{stagedir}/$name: $!\n";

    return $contents;
}

sub _write_file {
    my ( $self, $name, $contents ) = @_;

    my $path    = "$self->{stagedir}/$name";
    my $pathtmp = "$path.$$";
    sysopen my $fh, $pathtmp, O_CREAT | O_EXCL | O_WRONLY, 0644
      or LOGDIE "open $pathtmp: $!";
    print $fh $contents;
    close $fh or LOGDIE "close $pathtmp: $!";
    rename $pathtmp, $path
      or die "rename $pathtmp -> $path: $!\n";

    return;
}

sub _raw_index {
    my ( $self ) = @_;

    if( !$self->{raw_index} ) {
        my $file = "$self->{stagedir}/raw.idx";
        if( -f $file ) {
            $self->{raw_index} = YAML::XS::LoadFile( $file );
        } else {
            $self->{raw_index} = {};
        }
    }

    return $self->{raw_index};
}

sub _hosts_index {
    my ( $self ) = @_;

    if( !$self->{hosts_index} ) {
        my $file = "$self->{stagedir}/hosts.idx";
        if( -f $file ) {
            $self->{hosts_index} = YAML::XS::LoadFile( $file );
        } else {
            $self->{hosts_index} = {};
        }
    }

    return $self->{hosts_index};
}

1;
