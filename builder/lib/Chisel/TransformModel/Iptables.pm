######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::Iptables;

use strict;

use base 'Chisel::TransformModel';

sub new {
    my ( $class, %args ) = @_;
    $class->SUPER::new(
        ctx      => $args{'ctx'},
        contents => $args{'contents'},
        rules    => [],                  # iptables rules, as strings
    );
}

sub raw_needed {
    my ( $self, $action, @args ) = @_;

    my @needed;
    my $rule = $self->_parseargs( $action, @args );
    if( $rule && $rule->{srctype} && $rule->{src} && $rule->{srctype} eq 'host' ) {
        push @needed, 'dns/' . $rule->{src};
    } elsif( $rule && $rule->{srctype} && $rule->{src} && $rule->{srctype} eq 'role' ) {
        push @needed, 'dns/role:' . $rule->{src};
    }

    return @needed;
}

sub text {
    my ( $self ) = @_;

    my $filter_table = <<'EOT';
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:DUMP - [0:0]
EOT

    for my $rule ( @{ $self->{rules} } ) {
        $filter_table .= "$rule\n";
    }

    return $filter_table;
}

sub action_do {
    my ( $self, $action, @args ) = @_;

    my $rule = $self->_parseargs( $action, @args );
    if( !$rule ) {
        die "Invalid iptables rule [$action @args]\n";
    }

    return $self->_addrule( $rule );
}

sub action_accept {
    my ( $self, @args ) = @_;
    return $self->action_do( 'accept', @args );
}

sub action_reject {
    my ( $self, @args ) = @_;
    return $self->action_do( 'reject', @args );
}

sub action_drop {
    my ( $self, @args ) = @_;
    return $self->action_do( 'drop', @args );
}

sub action_truncate {
    my ( $self, @args ) = @_;
    @{ $self->{rules} } = ();
}

# convert rule from "_parserule" to iptables format and add to $self->{rules}
sub _addrule {
    my ( $self, $rule ) = @_;

    my $str = '-A INPUT';
    if( $rule->{srctype} && $rule->{srctype} eq 'ip' ) {
        # add /32 if not present
        if( $rule->{src} !~ m!/! ) {
            $rule->{src} .= '/32';
        }

        $str .= " -s $rule->{src}";
    } elsif( $rule->{srctype} && $rule->{srctype} eq 'host' ) {
        chomp( my $addr = $self->ctx->readraw( file => "dns/$rule->{src}" ) );
        if( $addr ) {
            $str .= " -s $addr/32";
        } elsif( $rule->{noexclude} ) {
            # bail out!
            die "Unresolvable hostname $rule->{src}";
        } else {
            # silently drop this rule.
            return 1;
        }
    } elsif( $rule->{srctype} && $rule->{srctype} eq 'role' ) {
        my @addrs = split /\n/, $self->ctx->readraw( file => "dns/role:$rule->{src}" );

        # recursively call _addrule and then stop
        foreach my $addr ( @addrs ) {
            if( $addr ) {
                my $newrule = {%$rule};
                $newrule->{srctype} = 'ip';
                $newrule->{src}     = $addr;
                $self->_addrule( $newrule );
            } elsif( $rule->{noexclude} ) {
                # bail out!
                die "Unresolvable hostname in role $rule->{src}";
            } else {
                # ok to continue
                next;
            }
        }

        return 1;
    }

    if( $rule->{port} && $rule->{proto} ) {
        $str .= " -p $rule->{proto} -m $rule->{proto} --dport $rule->{port}";
    }

    $str .= " -j " . uc $rule->{action};

    if( $rule->{action} eq 'reject' ) {
        $str .= " --reject-with icmp-port-unreachable";
    }

    push @{ $self->{rules} }, $str;
    return 1;
}


sub _parseargs {
    my ( $self, $action, @args ) = @_;

    my $rule = {};

    if( $action && ( $action eq 'accept' || $action eq 'reject' || $action eq 'drop' ) ) {
        # $action is cool.
        $rule->{action} = $action;
    } else {
        return undef;
    }

    # tokenize @args on whitespace if there is only one of them
    # otherwise assume it's pre-tokenize
    if( @args == 1 ) {
        @args = split /\s+/, $args[0];
    }

    # scan through @args
    my $key = undef;    # undef = want key, def = want value
    foreach my $arg ( @args ) {
        if( !defined $key ) {
            if( $arg eq 'host' || $arg eq 'role' || $arg eq 'ip' || $arg eq 'port' ) {
                $key = $arg;
            } elsif( $arg eq 'any' ) {
                # check conflict with other commands
                if( defined $rule->{src} ) {
                    return undef;
                }

                $rule->{srctype} = 'any';
                $rule->{src}     = '';
            } elsif( $arg eq 'noexclude' ) {
                $rule->{noexclude} = 1;
            } else {
                # bogus key, bail.
                return undef;
            }
        } elsif( $key eq 'host' || $key eq 'role' ) {
            # check conflict with other commands
            if( defined $rule->{src} ) {
                return undef;
            }

            $rule->{srctype} = $key;
            $rule->{src}     = $arg;
            undef $key;    # back to looking for a key
        } elsif( $key eq 'ip' ) {
            # check conflict with other commands
            if( defined $rule->{src} ) {
                return undef;
            }

            # check format
            # XXX not best check. but the sanity-check should be more comprehensive?
            # XXX if it existed, that is.
            if( $arg !~ /^(\d+\.\d+\.\d+\.\d+)(\/\d+)?\z/ ) {
                return undef;
            }

            # ok go
            $rule->{srctype} = 'ip';
            $rule->{src}     = $arg;
            undef $key;    # back to looking for a key
        } elsif( $key eq 'port' ) {
            # check conflict with other commands
            if( defined $rule->{port} ) {
                return undef;
            }

            # check format
            # XXX not best check. but the sanity-check should be more comprehensive?
            # XXX if it existed, that is.
            if( $arg =~ /^(\d+)\/(tcp|udp)\z/ ) {
                $rule->{port}  = $1;
                $rule->{proto} = $2;
            } else {
                return undef;
            }

            undef $key;    # back to looking for a key
        } else {
            # should never happen.
            die "INTERNAL ERROR: Bogus state [$key]";
        }
    }

    if( defined $key ) {
        # missing value.
        return undef;
    }

    if( !$rule->{srctype} && !$rule->{port} ) {
        # need either srctype or port
        return undef;
    }

    return $rule;
}

1;
