######################################################################
# Copyright (c) 2012, Yahoo! Inc. All rights reserved.
#
# This program is free software. You may copy or redistribute it under
# the same terms as Perl itself. Please see the LICENSE.Artistic file 
# included with this project for the terms of the Artistic License
# under which this project is licensed. 
######################################################################


package Chisel::TransformModel;

use strict;

use Carp;
use Hash::Util ();

sub new {
    my ( $class, %args ) = @_;

    # we allow starter contents to be passed in as 'contents'
    # if present, remove this key and save it for later
    my $contents = delete $args{'contents'};

    # create object
    my $self = {
        ctx => undef,
        %args
    };

    bless $self, $class;
    Hash::Util::lock_keys( %$self );

    # add 'contents' if it was provided
    if( defined $contents && length $contents ) {
        # XXX need unit test for this case
        $self->action_appendexact( $contents ) == 1
          or confess "Initial appendexact failed!";
    }

    return $self;
}

# stub method, should be implemented in subclasses
sub text { croak "unimplemented"; }

# get 'ctx', which may have been passed to the constructor.
sub ctx { shift->{ctx} }

# figure out what raw files are needed by a particular rule (action + args)
# it might not be *totally* correct (due to invokefor + invokefor or invokefor + include
# chaining shenanigans). that's fine, though, because in those cases it's seriously ok that
# the transform will fail to run.
sub raw_needed {
    my ( $self, $action, @rest ) = @_;

    my @needed;

    if( $action eq 'use' || $action eq 'include' ) {
        push @needed, $rest[0] if defined $rest[0];
    } elsif( $action eq 'invokefor' ) {
        my ( $rawfile, $action, $action_args ) = _invokefor_parse( @rest );

        # the referenced raw file is always needed
        if( $rawfile ) {
            push @needed, $rawfile;
        }

        # see if the action requires anything
        # check it without args, since if we check with args it would include a freaky {}

        push @needed, $self->raw_needed( $action );
    }

    # strip leading slashes, just like ->readraw would do
    s/^\/+// for @needed;
    return @needed;
}

# some actions can be expressed in terms of other actions,
# so they can have implementations in this base class.

# invoke an action for each line of a raw file
sub action_invokefor {
    my ( $self, @args ) = @_;

    my ( $rawfile, $action, $action_args ) = _invokefor_parse( @args )
      or return undef;

    # optimization: 'add' is significantly faster when run on lists instead of single users
    if( ( $action eq 'add' || $action eq 'srsadd' ) && $action_args =~ /^\s*\{\}\s*$/ ) {
        $action_args = '{,}';
    }

    my $sub = $self->can( "action_${action}" )
      or return undef;

    my @members = grep { $_ } split "\n", $self->ctx->readraw( file => $rawfile );
    return 1 unless @members;

    if( $action_args =~ /\{\}/ ) {    # multiple lines, replace {} on each
        foreach my $member ( @members ) {
            my $cur = $action_args;
            $cur =~ s/\{\}/$member/;
            my $r = $sub->( $self, $cur );
            return $r if !$r;
        }

        return 1;
    } elsif( $action_args =~ /\{([^\}]+)\}/ ) {    # one line, join on {X}
        my $joined_members = join $1, @members;
        $action_args =~ s/\{[^\}]+\}/$joined_members/;
    }

    return $sub->( $self, $action_args );
}

# helper to parse invokefor rules, since this is done in a couple places
# returns ( $rawfile, $action, $action_args )
sub _invokefor_parse {
    my ( @args ) = @_;

    if( @args == 3 ) {
        return ( @args );
    }

    elsif( @args == 1 && $args[0] =~ /^\s*(\S+)\s+(\S+)\s+(\S.+)$/ ) {
        return ( $1, $2, $3 );
    }

    elsif( @args == 1 && $args[0] =~ /^\s*(\S+)\s+(\S+)$/ ) {
        return ( $1, $2, '' );
    }

    else {
        return ();
    }
}

# do nothing
sub action_nop {
    return 1;
}

# stop processing and remove this file from the bucket
sub action_unlink {
    return 0;
}

# append with trailing newlines
sub action_append {
    my ( $self, @args ) = @_;
    @args = ( '' ) if !@args;    # if no @args provided, use a single blank line
    return $self->action_appendexact( map { "$_\n" } @args );
}

# simple search and replace
# requires helper "_replacere" to be defined in subclasses
sub action_replace {
    my ( $self, @args ) = @_;

    my ( $replace, $with );

    if( @args == 1 ) {
        # assume we got a single string
        my $line = $args[0] || '';
        ( $replace, $with ) = ( $line =~ /^(\S+)\s+(.*)$/ );
    } elsif( @args == 2 ) {
        # we got both args separately
        ( $replace, $with ) = @args;
    } else {
        # too many or too few args
        return undef;
    }

    $replace = quotemeta $replace;
    $with    = quotemeta $with;

    # call _replacere helper
    return $self->_replacere( $replace, $with );
}

# regexp-based search and replace, with backreferences
# requires helper "_replacere" to be defined in subclasses
sub action_replacere {
    my ( $self, @args ) = @_;

    my ( $replace, $with );

    if( @args == 1 ) {
        # assume we got a single string
        my $line = $args[0] || '';
        ( $replace, $with ) = ( $line =~ /^(\S+)\s+(.*)$/ );
    } elsif( @args == 2 ) {
        # we got both args separately
        ( $replace, $with ) = @args;
    } else {
        # too many or too few args
        return undef;
    }

    $replace = qr/$replace/;

    # we need to sanitize $with, basically we want to allow $N and ${N}-form backreferences but nothing else
    $with =~ s/\$([1-9][0-9]*)/\$\{$1\}/g;    # turn all $N-forms into ${N}-forms to prevent stuff like $1rofl
    $with = quotemeta $with;                  # escape everything
    $with =~ s/\\\$\\\{([1-9][0-9]*)\\\}/\$\{$1\}/g;    # unescape ${N}-form backreferences

    # call _replacere helper
    return $self->_replacere( $replace, $with );
}

# include a raw file
sub action_include {
    my ( $self, @args ) = @_;
    if( !@args ) {
        die "no argument provided";
    }
    return $self->action_appendexact( $self->ctx->readraw( file => $_ ) ) for @args;
}

# truncate, then include a raw file
sub action_use {
    my ( $self, @args ) = @_;
    my $ret = $self->action_truncate;
    return $ret == 1 ? $self->action_include( @args ) : $ret;
}

1;

__END__

=pod

=head3 nop

    - nop

Do nothing.

=head3 prepend

    - prepend text

    - - prepend
      - |
        multiple
        lines
        of text

Add text to the start of the file. The syntax in the second example makes use of a yaml
block literal (http://yaml.org/spec/1.1/index.html#id928909).

=head3 append

    - append one line of text

    - - append
      - |
        multiple
        lines
        of text

Add text to the end of the file. The syntax in the second example makes use of a yaml
block literal (http://yaml.org/spec/1.1/index.html#id928909).

=head3 appendunique

    - [ 'appendunique', 'server 1.2.3.4' ]

Add a line to the end of the file if an exact match is not found anywhere else
in the file.

=head3 delete

    - delete bbb

Delete any line that matches, chararacter for character (no partial matches, no
regular expressions).

=head3 deletere

    - deletere [ab]{3}

Deletes any line matching a particular regular expression. Partial matches are
allowed.

=head3 unlink

    - unlink

Remove this file from the bucket. This is final, and cannot be overruled by
later transforms.

=head3 include

    - include sudoers.minimal

Append the contents of a file in the raw/ directory.

=head3 use

    - use hosts.allow.prod

Replace the current file with one from the raw/ directory. This is just a
shorthand for "truncate" followed by "include".

=head3 use_binary

    - use_binary hosts.allow.prod

B<Deprecated.> Equivalent to C<use>.

=head3 replace

    - replace foo.bar foo.baz
    - [ replace, 'foo.bar', 'foo.baz' ]

Replace one literal string with another, globally throughout the file. The two
examples given are equivalent, and will both turn:

    xyz fooxbar
    xyz foo.bar

into:

    xyz fooxbar
    xyz foo.baz

=head3 replacere

    - replacere foo.bar foo.baz
    - [ replacere, 'foo.bar', 'foo.baz' ]

Replace as Perl would using a regular expression, globally throughout the file.
The two examples given are equivalent, and will both turn:

    xyz fooxbar
    xyz foo.bar

into:

    xyz foo.baz
    xyz foo.baz

The replacement string may include backreferences in the $1, $2, $10, etc form
(or possibly the ${1} form), but all other syntax is forbidden.

=head3 truncate

    - truncate

Truncate the current file, leaving it zero-length.

=head3 dedupe

    - dedupe

Remove all duplicate lines in the file, even those that are non-adjacent. Keeps
the first one.

=head3 invokefor

    - invokefor group_role/ybiip.bootserver append push_to {}
    - [ invokefor, group_role/ybiip.bootserver, append, 'push_to {}' ]

Invokes another action for each member of a group expression, replacing C<{}>
with one member for each invokation. This example will append something like:

    push_to ybiip1-1-flk.ops.sp2.fake-domain.com
    push_to ybiip1-1-prd.ops.sp2.fake-domain.com
    ...

And so on, for each member of C<group_role/ybiip.bootserver>.

If the curly braces have some sort of string between them, this will invoke the
action only once, with the curly braces replaced by a list of all members
joined by that string. For example,

    - invokefor group_role/ybiip.bootserver append push_to {, }

Will append something like:

    push_to ybiip1-1-flk.ops.sp2.fake-domain.com, ybiip1-1-prd.ops.sp2.fake-domain.com, ...

Only the first set of curly braces will be replaced. If the group has no
members, C<invokefor> is a no-op. If there are no curly braces, the command
will be invoked once without any substitution. This can be used as a way to
print a line conditionally based on whether or not a group has any members, so:

    - invokefor group_role/ybiip.bootserver append the role is nonempty

Will append "the role is nonempty" if the role has any members, and will be a
no-op if the role has no members.

=head3 add

    passwd:
      - add bob, carol
      - [ add, bob, carol ]

F<passwd> specific. Users will be assigned a shell, UID, GID, and password
based on passwd source of truth unless another transform alters them. Users that are not present
in the source of truth will be silently skipped (use C<srsadd> if you want this to be an error).

=head3 srsadd

    passwd:
      - srsadd bob, carol
      - [ srsadd, bob, carol ]

For when you really want to add a user. This is the same as C<add>, except
attempting to add a user that is not present in the source of truth will cause C<srsadd> to
bail out. This will prevent the configuration from propagating out to
production.

=head3 remove

    passwd:
      - remove bob, carol
      - [ remove, bob, carol ]

Probably only useful for C<passwd> and C<group>. Removes lines that are
identically "bob" or start with "bob:". This could be accomplished with
deletere, but is provided as a convenience.

=head3 chsh

    passwd:
      - add bldotron
      - chsh bldotron /bin/bash

Changes a user's shell. This could be accomplished with replacere, but is
provided as a convenience.

=head3 sortuid

    - sortuid

Sorts a colon-delimited file by the third element on each line. Note: this
is done automatically for C<passwd> and C<group>. There is no need to call
it manually.

=head3 addkey

    homedir:
      - addkey bob from="myhost.fake-domain.com" ssh-rsa AAAAkeykeykeykeyk+eyZZZ mycomment

Adds a value to a key in a YAML document. Only useful if the file being
transformed is a hash-of-list YAML document, like C<homedir> (ssh
authorized_keys).

=head3 clearkey

    homedir:
      - clearkey bob

Removes a key from a YAML document. Only useful if the file being transformed
is a hash-of-list YAML document, like C<homedir> (ssh authorized_keys).

=head3 give_me_all_users

    passwd:
      - give_me_all_users # use default shell

    passwd:
      - give_me_all_users shell=/sbin/nologin # shell override

Adds B<every> user from the source of truth, including headless accounts, which will also lead
to provisioning of home directories and authorized_keys. 

With no arguments, users will get their default shells. Normally this is bash
for humans and push for headless accounts, although there are numerous exceptions. If
you want users to have a special shell, you may override the default with a shell of
your choosing. Note that if you do this, you should make sure this transform runs
B<last> (the C<give_me_all_users> rule will not modify the shell of a user added
by a previous rule). This can be accomplished using the C<follows> directive (see
L<TransformSyntax>).
