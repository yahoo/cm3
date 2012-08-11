######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel::PasswdLike;

use strict;

use base 'Chisel::TransformModel';

use Carp;

sub new {
    my ( $class, %args ) = @_;
    $class->SUPER::new(
        ctx      => $args{'ctx'},
        contents => $args{'contents'},
        rows     => {},
    );
}

sub text {
    my ( $self ) = @_;

    return join '',    # joined into one string
      map { "$_->{text}\n" }    # text lines
      sort { $a->{'id'} <=> $b->{'id'} or $a->{'name'} cmp $b->{'name'} }    # sorted by id, then by name
      values %{ $self->{'rows'} };
}

sub raw_needed {
    my ( $self, $action, @rest ) = @_;

    my @needed;

    if( $action eq 'add' || $action eq 'srsadd' ) {
        push @needed, $self->_rawsrc;
    } else {
        push @needed, $self->SUPER::raw_needed( $action, @rest );
    }

    return @needed;
}

# name of the raw file this model is based on (something like 'passwd' or 'group')
sub _rawsrc { croak "unimplemented"; }

# regexp for names in this model
sub _nameregexp { croak "unimplemented"; }

# resolve conflicts between two text lines that correspond to the same name/id pair
# inputs:
#  A      -> hash for row one
#  B      -> hash for row two
# outputs:
#  merged line, or, undef if no merge is possible
# example:
#  A      -> operator:*:5:root,bob
#  B      -> operator:*:5:root
#  return -> operator:*:5:root,bob

sub _merge {
    return undef;
}

# add a row from _rawsrc, returns undef if it's not found
sub action_srsadd {
    my ( $self, @args ) = @_;

    # normalize arguments (there could be commas separating them)
    @args = map { split /\s*,\s*/ } @args;

    # load rawsrc map
    my $map = $self->_map;

    # eventual return value
    my $ret = 1;

    for my $arg ( @args ) {
        $arg =~ s/^\s+//;
        $arg =~ s/\s+$//;

        my $dude = $map->{$arg};

        if( !$dude ) {
            # dude not found, this is an error
            $ret = undef;
            next;
        }

        # add this row
        # if the add fails, that's ok. it means the name is already in the model with different details.
        $self->_addrow( $dude );
    }

    return $ret;
}

# same as srsadd, but always return OK
sub action_add {
    my ( $self, @args ) = @_;

    $self->action_srsadd( @args );

    return 1;
}

# remove rows
sub action_remove {
    my ( $self, @args ) = @_;
    delete $self->{'rows'}{$_} for map { split /\s*,\s*/ } @args;
    return 1;
}

# add rows from raw text
sub action_appendexact {
    my ( $self, @args ) = @_;

    # append raw text
    # just convert it to our internal format
    # if we can't convert it, return undef to signify error

    foreach my $arg ( map { split /\n/ } @args ) {

        if( my $row = $self->_parsetext( $arg ) ) {

            # try to add this row
            my $added = $self->_addrow( $row );

            if( !$self->_addrow( $row ) ) {
                die "'$row->{name}' is already present and cannot be merged\n";
            }
        } elsif( $arg =~ /^#/ || $arg =~ /^[ \t]*$/ ) {
            # ignore comments and whitespace or blank lines
        } else {
            # bail out since this $arg is not properly formatted
            die "append of incorrectly formatted text";
        }
    }

    return 1;
}

# same implementation as appendexact
sub action_appendunique {
    my ( $self, @args ) = @_;
    return $self->action_appendexact( @args );
}

# same implementation as appendexact
sub action_prepend {
    my ( $self, @args ) = @_;
    return $self->action_appendexact( @args );
}

# delete verbatim row
sub action_delete {
    my ( $self, @args ) = @_;
    return $self->action_deletere( map { '^' . ( quotemeta $_ ) . '$' } @args );
}

# delete rows matching a regex
sub action_deletere {
    my ( $self, @args ) = @_;

    if( @args != 1 ) {
        # need exactly 1 arg
        return undef;
    }

    no re 'eval';    # just in case
    foreach my $rowname ( keys %{ $self->{rows} } ) {
        if( $self->{rows}{$rowname}{text} =~ /$args[0]/ ) {
            delete $self->{rows}{$rowname};
        }
    }

    return 1;
}

# replacere helper (see base class for info)
sub _replacere {
    my ( $self, $replace, $with ) = @_;

    # just in case
    no re 'eval';

    # run this replacement on every row
    my @rownames = keys %{ $self->{'rows'} };

    my $evalstr = <<'EOT';
    foreach my $rowname ( @rownames ) {
        if( $self->{rows}{$rowname}{text} =~ s/$replace/::with::/g ) {
            # something was replaced

            # skip comments and blank lines
            if( $self->{rows}{$rowname}{text} =~ /^#/ || length( $self->{rows}{$rowname}{text} ) == 0 ) {
                delete $self->{rows}{$rowname};
                next;
            }

            # need to check if the name/id changed so we can reindex
            my $newrow = $self->_parsetext( $self->{rows}{$rowname}{text} );

            if( !defined $newrow ) {
                # uh oh. we were replace'd into something that is totally not a legit row.
                die "'$rowname' was transformed into an invalid row";
            } elsif( $newrow->{name} ne $rowname or $newrow->{id} ne $self->{rows}{$rowname}{id} ) {
                # need to reindex.

                # first, make sure this will not introduce a name conflict.
                if( $newrow->{name} ne $rowname and $self->{rows}{ $newrow->{name} } ) {
                    die "'$rowname' was transformed into '$newrow->{name}' which is already present";
                }

                # remove old row
                my $row = delete $self->{rows}{$rowname};

                # add $newrow with the new name/id
                $self->{rows}{ $newrow->{name} } = $newrow;
            }
        }
    }
EOT

    $evalstr =~ s/::with::/$with/;

    eval $evalstr;

    if( $@ ) {
        # eval failed
        die $@;
    }

    return 1;
}

# remove all rows
sub action_truncate {
    my ( $self ) = @_;
    $self->{'rows'} = {};
    return 1;
}

# no-ops, since we already sort + dedupe
sub action_sortuid { 1; }
sub action_dedupe  { 1; }

# helper for adding a parsed row to our model
# will try to merge if a row with the same name already exists
# returns 1 if the row was added
# returns 0 if the row could not be added (failed merge)
sub _addrow {
    my ( $self, $newrow ) = @_;

    if( my $oldrow = $self->{rows}{ $newrow->{name} } ) {
        # this name already exists.
        # - return 0 if the new line has a different id
        # - attempt merge if the new line is different but has the same id
        # - ignore if the new line is identical
        if( $oldrow->{id} ne $newrow->{id} ) {
            return 0;
        } elsif( $oldrow->{text} ne $newrow->{text} ) {
            my $merged = $self->_merge( $oldrow, $newrow );
            if( $merged ) {
                # merge successful
                $newrow->{text} = $merged;
                $self->{rows}{ $newrow->{name} } = {%$newrow};
            } else {
                # merge failed
                return 0;
            }
        }
    } else {
        # name does not already exist. just add the row
        $self->{rows}{ $newrow->{name} } = {%$newrow};
    }

    # must have been successful if we got this far
    return 1;
}

# helper for parsing text and turning it into name/id/text hash
# returns undef if the text does not look like a legit line
sub _parsetext {
    my ( $self, $text ) = @_;

    my $nameregexp = $self->_nameregexp;

    chomp $text;

    if( $text =~ /^($nameregexp):[^:]*:(\d+):/ ) {
        return {
            name => $1,
            id   => $2,
            text => $text,
        };
    } else {
        return undef;
    }
}

# helper for loading a parsed map of our _rawsrc, and caching it in 'ctx'
sub _map {
    my ( $self ) = @_;
    my $rawsrc = $self->_rawsrc;

    unless( $self->ctx->{map}{$rawsrc} ) {
        my %smap;
        my $rows = [ split "\n", $self->ctx->readraw( file => $rawsrc ) ];

        foreach my $row ( @$rows ) {
            if( my $rmap = $self->_parsetext( $row ) ) {
                $smap{ $rmap->{name} } = $rmap;
            }
        }

        $self->ctx->{map}{$rawsrc} = \%smap;
    }

    return $self->ctx->{map}{$rawsrc};
}

1;
