use v5.20.0;
use warnings;

package String::Switches;

use experimental qw( signatures );

use utf8;

use Carp;

use Sub::Exporter -setup => [ qw( parse_switches canonicalize_names) ];

=head1 SYNOPSIS

  my ($switches, $err) = parse_switches($user_input);

  die $err if $err;

  for my $switch (@$switches) {
    my ($name, $value) = @$switch;
    say "/$name = $value";
  }

=cut


# Even a quoted string can't contain control characters.  Get real.
our $qstring    = qr{[“"]( (?: \\["“”] | [^\pC"“”] )+ )[”"]}x;

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

sub canonicalize_names ($hunks, $aliases = {}) {
  $_->[0] = $aliases->{ fc $_->[0] } // fc $_->[0] for @$hunks;
  return;
}

our $ident_re = qr{[-a-zA-Z][-_a-zA-Z0-9]*};

sub parse_colonstrings ($text, $arg) {
  my @hunks;

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

    push @hunks, $arg->{fallback}->(\$text) if $arg->{fallback};
  }

  return \@hunks;
}

1;
