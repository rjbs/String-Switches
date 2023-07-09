use v5.32.0;
use warnings;

package String::Switches;
# ABSTRACT: functions for parsing /switches and similarly constructed strings

use experimental qw( signatures );

use utf8;

use Carp;

use Sub::Exporter -setup => [ qw(
  parse_switches
  parse_colonstrings
  canonicalize_names
) ];

=head1 SYNOPSIS

  use String::Switches qw( parse_switches );

  my ($switches, $err) = parse_switches($user_input);

  die $err if $err;

  for my $switch (@$switches) {
    my ($name, $value) = @$switch;
    say "/$name = $value";
  }

=cut

# Even a quoted string can't contain control characters.  Get real.
our $qstring    = qr{[“"]( (?: \\["“”] | [^\pC"“”] )+ )[”"]}x;

=func parse_switches

  my ($switches, $err) = parse_switches($user_input);

This expects a string of "switches", something like you might pass to a program
in the DOS terminal on Windows.  It was created to parse commands given to a
chatbot, and so has some quirks based on that origin.

The input should be a sequence of switches, like C</switch>, each one
optionally followed by arguments.  So, for example:

  /coffee /milk soy /brand "Blind Tiger" /temp hot /sugar /syrup ginger vanilla

The return is either C<($switches, undef)> or C<(undef, $error)>  If parsing
fails, the error will be a string describing what happened.  This string may
change in the future.  Do not rely on its exact contents.

If parsing succeeds, C<$switches> will be a reference to an array, each element
of which will also be a reference to an array.  Each of the inner arrays is in
the form:

  ($command, @args)

The example above, then, would be parsed into a C<$switches> like this:

  [
    [ "coffee" ],
    [ "milk",  "soy" ],
    [ "brand", "Blind Tiger" ],
    [ "temp",  "hot",
    [ "sugar" ],
    [ "syrup", "ginger", "vanilla" ],
  ]

Multiple non-switches after a switch become multiple arguments.  To make them
one argument, use double quotes.  In addition to ASCII double quotes, "smart
quotes" work, to cope with systems that automatically smarten quotes.

=cut

sub parse_switches ($string) {
  my @tokens;

  # The tokens we really want:
  #   command   := '/' identifier
  #   safestr   := not-slash+ spaceslash-or-end
  #   quotestr  := '"' ( qchar | not-dquote )* '"' ws-or-end

  while (length $string) {
    $string =~ s{\A\s+}{}g;
    $string =~ s{\s+\z}{}g;

    if ($string =~ s{ \A /([-a-z]+) (\s* | $) }{}x) {
      push @tokens, [ cmd => $1 ];
      next;
    } elsif ($string =~ s{ \A /(\S+) (\s* | $) }{}x) {
      return (undef, "bogus /command: /$1");
    } elsif ($string =~ s{ \A / (\s* | $) }{}x) {
      return (undef, "bogus input: / with no command!");
    } elsif ($string =~ s{ \A $qstring (\s* | $)}{}x) {
      my $match = $1;
      push @tokens, [ lit => $match =~ s/\\(["“”])/$1/gr ];
      next;
    } elsif ($string =~ s{ \A (\S+) (\s* | $) }{}x) {
      my $token = $1;

      return (undef, "unquoted arguments may not contain slash")
        if $token =~ m{/};

      push @tokens, [ lit => $token ];
      next;
    }

    return (undef, "incomprehensible input");
  }

  my @switches;

  while (my $token = shift @tokens) {
    if ($token->[0] eq 'badcmd') {
      Carp::confess("unreachable code");
    }

    if ($token->[0] eq 'cmd') {
      push @switches, [ $token->[1] ];
      next;
    }

    if ($token->[0] eq 'lit') {
      return (undef, "text with no switch") unless @switches;
      push $switches[-1]->@*, $token->[1];
      next;
    }

    Carp::confess("unreachable code");
  }

  return (\@switches, undef);
}

=func parse_colonstrings

  my $hunks = parse_colonstrings($input_text, \%arg);

B<Achtung!>  The interface to this function may change a bit in the future, to
make it act more like the switch parser, and to make it easier to get a simple
fallback.

Like C<parse_switches>, this is intended to parse user input into a useful
structure.  Instead of C</switch>-like input, it expects the sort of thing you
might type into a search bar, like:

  best "thanksgiving recipe" type:pie

You can provide the C<fallback> argument in C<%arg>, which should be a
reference to a subroutine.  When a hunk of input is reached that doesn't look
like C<key:value>, the fallback callback is called, and passed a reference to
the string being parsed.  It's expected to modify that string in place to
remove whatever it consumes, and then return a value to put into the returned
arrayref.

If that sounds confusing, consider passing C<literal>, instead.  The value
should be a name to be used as the key when a no-key hunk of text is found.

For example, given this code:

  my $hunks = parse_colonstrings(
    q{foo:bar baz quux:"Trail Mix"},
    { literal => 'other' },
  );

The result is:

  [
    [ foo     => 'bar' ],
    [ other   => 'baz' ],
    [ quux    => 'Trail Mix' ],
  ]

Like C<parse_switches>, smart quotes work.

=cut

our $ident_re = qr{[-a-zA-Z][-_a-zA-Z0-9]*};

my sub mk_literal_fb ($literal) {
  return sub ($text_ref) {
    ((my $token), $$text_ref) = split /\s+/, $$text_ref, 2;

    return [ $literal => $token ];
  };
}

sub parse_colonstrings ($text, $arg) {
  my @hunks;

  my $fallback = defined $arg->{fallback} ? $arg->{fallback}
               : defined $arg->{literal}  ? mk_literal_fb($arg->{literal})
               :                            undef;

  state $switch_re = qr{
    \A
    ($ident_re)
    (
      (?: : (?: $qstring | [^\s:"“”]+ ))+
    )
    (?: \s | \z )
  }x;

  my $last = q{};
  TOKEN: while (length $text) {
    $text =~ s/^\s+//;

    # Abort!  Shouldn't happen. -- rjbs, 2018-06-30
    return undef if $last eq $text;

    $last = $text;

    if ($text =~ s/$switch_re//) {
      my @hunk = ($1);
      my $rest = $2;

      while ($rest =~ s{\A : (?: $qstring | ([^\s:"“”]+) ) }{}x) {
        push @hunk, length $1 ? ($1 =~ s/\\(["“”])/$1/gr) : $2;
      }

      push @hunks, \@hunk;

      next TOKEN;
    }

    push @hunks, $fallback->(\$text) if $fallback;
  }

  return \@hunks;
}

=func canonicalize_names

  canonicalize_names($switches, \%aliases);

This function takes the C<$switches> result of C<parse_switches> and
canonicalizes names.  The passed switches structure is I<altered in place>.

Every switch name is fold-cased.  Further, if C<$aliases> is given and has an
entry for the fold-cased switch name, the value is used instead.  So for
example:

  my ($switches)  = parse_switches("/urgency high");
  canonicalize_names($switches, { urgency => 'priority' });

At the end of the code above, C<$switches> contains:

  [
    [ "priority", "high" ],
  ]

=cut

sub canonicalize_names ($hunks, $aliases = {}) {
  $_->[0] = $aliases->{ fc $_->[0] } // fc $_->[0] for @$hunks;
  return;
}

1;
