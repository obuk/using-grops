#!/usr/bin/env perl
use strict;
use warnings;
use Mojolicious::Lite;
use URI::Encode qw(uri_encode);
use File::Path qw(make_path);
use File::Spec::Functions;
use File::Basename;
use utf8;

binmode STDERR, ":utf8";

plugin('Config');

get '/' => sub {
  my $c = shift;
  $c->render(template => 'index');
};

get '/man/#name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  warn "# name = $name\n";
  my (undef, $sect, $lang) = man_where($c, $name);
  if ($sect) {
    $c->redirect_to("/man/$sect/$name");
  } else {
    $c->reply->not_found;
  }
};

get '/man/:sect/#name' => sub {
  my $c = shift;
  my $name = $c->stash('name');
  my ($src, $sect, $lang) = man_where($c, $name, $c->stash('sect'));
  my $cache = $c->app->config('cache') || '.cache';
  my $dest = catfile grep defined, $cache, $lang, $sect, $name;
  make_path dirname $dest;
  if (! -f $dest || $c->app->config('force')) {
    if ($src) {
      my $cat = $src =~ /\.gz$/? "zcat" : "cat";
      $cat = "$cat $src";
      my $iconv;
      $iconv = $c->app->config("iconv_$lang") if $lang;
      $iconv //= $c->app->config("iconv");
      $cat = "$cat | $iconv" if $iconv;
      my @lines;
      if (open my ($fd), "-|:utf8", $cat) {
	@lines = <$fd>;
	close $fd;
      }
      add_links($c, "/man", \@lines);
      my $groff = $c->app->config("groff_$lang") if $lang;
      $groff //= $c->app->config("groff");
      my $gs = $c->app->config("gs_$lang") if $lang;
      $gs //= $c->app->config("gs");
      my $groff_gs = $gs ? "$groff | $gs" : $groff;
      warn "# $cat | $groff_gs\n";
      if (open my ($fd), "|-:utf8", "tee $dest.t | $groff_gs > $dest") {
	print {$fd} @lines;
	print {$fd} ".pdfview /PageMode /UseOutlines\n";
	close $fd;
      }
    }
  }
  if (-f $dest) {
    my $pdf = `cat $dest`;
    $c->render(data => $pdf, format => 'pdf');
  } else {
    $c->reply->not_found;
  }
};

sub man_where {
  my ($c, $name, $sect) = @_;
  my $lang = $c->param('lang') // $c->app->config('lang');
  $lang = '' if $lang && $lang eq 'en';
  $sect //= '';
  my $man = "man -w" . ($lang ? " -L$lang" : "");
  chop(my $where = `$man $sect $name`);
  if ($lang) {
    if ($where =~ m{(?:/($lang))?/man(\w+)/}) {
      ($sect, $lang) = ($2, $1);
    }
  } else {
    if ($where =~ m{/man(\w+)/}) {
      $sect = $1;
    }
  }
  ($where, $sect, $lang);
}

sub parse_args {
  if (@_ && $_[0]) {
    local $_ = join ' ', grep defined, @_;
    my (@args, @punct);
    while (s/^\s*(?:["]([^\"]*)["]\s*|((?:[\\]\s|[^\s])+))\s*//g) {
      push @args, grep defined, $1 // $2;
    }
    return @args;
  }
  '';
}

sub pdfhref {
  my $f = shift;
  my %x;
  while (@_ && $_[0] =~ /^-/) {
    my $opt = shift;
    last if $opt eq '--';
    $x{$opt} = shift;
  }

  defined $x{-D} and $x{-D} =~ s/\\[:&%]//g;
  defined $x{-P} and $x{-P} =~ s/\\m(?:[^\(\[]|[(]..|[\[][^\]]*[\]])//g;
  defined $x{-A} and $x{-A} =~ s/\\m(?:[^\(\[]|[(]..|[\[][^\]]*[\]])//g;

  my $text = "@_";
  $text =~ s/(\/)(\w)/$1\\:$2/g;
  $text =~ s/(\.)(\w)/\\&$1$2/g;

  if (uc($f) eq 'W') {
    return join " ", ".pdfhref", uc($f),
      (map { $x{$_} ? ($_, $x{$_}) : () } qw/-D -P -A/), '--',
      $text;
  }
  if (uc($f) eq 'L') {
    return join " ", ".pdfhref", uc($f),
      (map { $x{$_} ? ($_, $x{$_}) : () } qw/-D -P -A/),
      (grep defined $x{$_}, qw/-X/), '--',
      $text;
  }
  if (uc($f) eq 'M') {
    return join " ", ".pdfhref", uc($f),
      (map { $x{$_} ? ($_, $x{$_}) : () } qw/-N/),
      (grep defined $x{$_}, qw/-X -E/),
      $text;
  }
  if (uc($f) eq 'O') {
    return join " ", ".pdfhref", uc($f),
      $text;
  }

}

sub add_links {
  my $c = shift;
  my $me = $c->url_for(shift)->to_abs;
  my $lines = shift;

  my %tag;
  for (@$lines) {
    if (/^[.]\s*(SH|SS|Sh|Ss)\s+(.*?)\s*$/) {
      my ($req, @args) = ($1, parse_args($2));
      my $text = "@args";
      $tag{$text} = uri_encode($text);
      $tag{$text} =~ s/%20/-/g;
      $tag{$text} =~ tr[()\[\]<>{}\/%][.];
    }
  }

  my $re_pre = qr/(?:[<]|\\[fm](?:[^\(\[]|[(]..|\[[^\]]*\]))+/;
  my $re_aff = qr/(?:[>]|\\[fm](?:[^\(\[]|[(]..|\[[^\]]*\]))+/;

  my @ur;
  my $tp = 0;
  for (@$lines) {
    if (/^[.]\s*UR/ ... /^[.]\s*UE/) {
      if (/^[.]\s*UR\s+(.*?)\s*$/) {
        @ur = ($1);
        chomp($ur[-1]);
        s/^/.\\" /;
      } elsif (/^[.]\s*UE\s+(.*?)\s*$/) {
	my ($dest, $aff) = (shift(@ur), $1);
        s/^/.\\" /;
	$_ .= pdfhref 'W', -D => $dest, -A => $aff, '--',
	  "@ur\n";
      } else {
	if (/^[.]\s*(B|I)\s+(.*?)\s*$/) {
	  push @ur, "\\f$1$2\\fP";
	} elsif (/^[.]\s*(SB)\s+(.*?)\s*$/) {
	  push @ur, "\\'s-1'\\fB$2\\fP\\'s+1'";
	} elsif (/^[.]\s*(SM)\s+(.*?)\s*$/) {
	  push @ur, "\\s'-1'$2\\s'+1'";
	} elsif (/^[.]\s*(BI|BR|IB|IR|RB|RI)\s+(.*?)\s*$/) {
	  my ($req, @args) = ($1, parse_args($2));
	  while (@args) {
	    my ($text, $aff) = splice @args, 0, 2;
	    push @ur,
	      "\\f".substr($req, 0, 1).$text.
	      "\\f".substr($req, 1, 1).$aff;
	  }
	} else {
	  push @ur, $_;
	  chomp($ur[-1]);
	}
        s/^/.\\" /;
      }
    } elsif (/^[.]\s*(Xr)\s+(.*?)\s*$/) {
      my ($req, $text, $aff, $pre) = ($1, $2);
      my @args = parse_args($text);
      my @punct;
      unshift @punct, pop @args while @args > 1 && $args[-1] =~ /^[[:punct:]]/;
      ($text, $aff, $pre) = ("@args", @punct);
      my $sect = pop @args;
      my $name = "@args";
      if ($name && $name =~ /^(?:\\%)?\w/ && $sect && $sect =~ /^\d\w*/) {
	my $dest = "$me/$sect/$name";
        s/^/.\\" /;
	$_ .= pdfhref 'W', -D => $dest, -P => $pre, -A => $aff, '--',
	  "\\fB$name\\fR($sect)\n";
      }
    } elsif (/^[.]\s*(Sh|Ss|SH|SS)\s+(.*?)\s*$/) {
      my ($req, $text, $aff, $pre) = ($1, $2);
      my @args = parse_args($text);
      my @punct;
      unshift @punct, pop @args while @args > 1 && $args[-1] =~ /^[[:punct:]]/;
      ($text, $aff, $pre) = ("@args", @punct);
      $_ .= pdfhref 'O', 1, "$text\n" if $req =~ /Sh/i;
      $_ .= pdfhref 'O', 2, "$text\n" if $req =~ /Ss/i;
      if (my $tag = $tag{$text}) {
        #s/^/.\\" /;
	$_ .= pdfhref 'M', -N => $tag, -P => $pre, -A => $aff,
	  "$text\n";
      }
    } elsif (/^[.]\s*(S[xy]|Tn)\s+(.*?)\s*$/) {
      my ($req, $text, $aff, $pre) = ($1, $2);
      my @args = parse_args($text);
      my @punct;
      unshift @punct, pop @args while @args > 1 && $args[-1] =~ /^[[:punct:]]/;
      ($text, $aff, $pre) = ("@args", @punct);
      if (my $tag = $tag{$text}) {
        s/^/.\\" /;
        $_ .= pdfhref 'L', -D => $tag, -P => $pre, -A => $aff, '--',
	  "\\fB$text\\fR\n";
      } elsif ($text =~ /^(?:\\%)?\w/ && $aff && $aff =~ s/[(](\d\w*)[)]//) {
	my ($name, $sect) = ($text, $1);
	my $dest = "$me/$sect/$name";
	$_ .= pdfhref 'W', -D => $dest, -P => $pre, -A => $aff, '--',
	  "\\fB$name\\fR($sect)\n";
      } elsif ($text =~ s/($re_pre)?((?:https?|ftp):\/\/\S+)($re_aff)?\s*//) {
	my ($pre, $dest, $aff) = ($1, $2, $3);
	s/^/.\\" /;
	$_ .= pdfhref 'W', -D => $dest, -P => $pre, -A => $aff, '--',
	  "\\fB$dest\\fR\n";
	$_ .= $text . "\n" if $text;
      }

    } elsif (/^[.]\s*(B|I)\s+(.*?)\s*$/) { # and SM, SB
      my ($req, @args) = ($1, parse_args($2));
      my $text = "@args";
      if (my $tag = $tag{$text}) {
        s/^/.\\" /;
        $_ .= pdfhref 'L', -D => $tag, '--',
	  "\\f$req$text\\fP\n";
      }

    } elsif (/^[.]\s*(BI|BR|IB|IR|RB|RI)\s+(.*?)\s*$/) {
      my ($req, @args) = ($1, parse_args($2));
      my @fnts = map substr($req, $_ % 2, 1), 0 .. $#args;
      my $save = $_;
      s/^/.\\" /;
      my $pdfhref;
      while (@args) {
	my ($text, $fn) = (shift @args, shift @fnts);
	if ($text =~ /^(?:\\%)?\w/ &&
	    @args && $args[0] =~ s/^[(](\d\w*)[)](\S*)\s*//) {
	  my ($name, $sect, $aff) = ($text, $1, $2);
	  my $dest = "$me/$sect/$name";
	  $_ .= pdfhref 'W', -D => $dest, -A => $aff, '--',
	    "\\f$fn$name\\fP\\f$fnts[0]($sect)\\fP\n";
	  $_ .= $args[0] . "\n" if $args[0];
	  shift @args; shift @fnts;
	  $pdfhref++;
	} elsif ($text =~ s/^($re_pre)?((?:https?|ftp):\/\/\S+)($re_aff)?\s*//) {
	  my ($pre, $dest, $aff) = ($1, $2, $3);
	  $_ .= pdfhref 'W', -D => $dest, -P => $pre, -A => $aff, '--',
	    "\\f$fn$dest\\fP\n";
	  $_ .= $text . "\n" if $text;
	  $pdfhref++;
	} else {
	  s/\\c\n$//s;
	  $_ .= "\\f$fn$text\\fP\\c\n";
	}
      }
      if ($pdfhref) {
	s/\\c\n$/\n/s;
      } else {
	$_ = $save;
      }

    } elsif (/^[.]\s*TS/ ... /^[.]\s*TE/) {
	;
    } elsif (/^[.]\s*TP(?:\s.*)?$/) {
      $_ .= ".TP*MORE\n";
      $tp = 1;
    } elsif (/^[.]/) {
      ;
    } else {
      if (s{(.*?)($re_pre)((?:\\%)?\w+[-\w]*)($re_aff)[(](\d\w*)[)](\S*)\s*}{
	my ($left, $fb, $name, $fr, $sect, $aff) = ($1, $2, $3, $4, $5, $6);
        ($left ? "$left\\c\n" : "").
	  pdfhref 'W', -D => "$me/$sect/$name", -A => $aff, "--",
	  "$fb$name$fr($sect)\n"
	}ge) {
	;
      } elsif (s{(.*?)($re_pre)((?:\\%)?\w+[-\w]*)[(](\d\w*)[)]($re_aff)(\S*)\s*}{
	my ($left, $fb, $name, $sect, $fr, $aff) = ($1, $2, $3, $4, $5, $6);
        ($left ? "$left\\c\n" : "").
	  pdfhref 'W', -D => "$me/$sect/$name", -A => $aff, "--",
	  "$fb$name$fr($sect)\n"
	}ge) {
	;
      } elsif (s{(.*?)((?:\\%)?\w+[-\w]*)[(](\d\w*)[)](\S*)\s*}{
	my ($left, $name, $sect, $aff) = ($1, $2, $3, $4);
	(my $name_clean = $name) =~ s/\\%//g;
        ($left ? "$left\\c\n" : "").
	  pdfhref 'W', -D => "$me/$sect/$name", -A => $aff, "--",
	  "$name($sect)\n"
	}ge) {
	;
      } elsif (s{(.*?)($re_pre)((?:https?|ftp)://\S*)\s*}{
	my ($left, $pre, $dest) = ($1, $2, $3); $dest =~ s/\\[:&%]//g;
	my $aff = do { $dest =~ s/(?:$re_aff|[.])+$//g ? $& : '' };
	($left ? "$left\\c\n" : "").
	  pdfhref 'W', -D => $dest, -P => $pre, -A => $aff, '--',
	  "\\fB$dest\\fR\n";
	}ge) {
	;
      }
    }

    if (!/^[.]/ || /^[.]\s*(SH|SS|SM|SB|BI|IB|RI|IR|BR|RB|R|B|I|pdfhref)\b/m) {
      if ($tp > 0 && --$tp == 0) {
	$_ .= ".TP*END\n";
      }
    }

  }
}

app->start;

__DATA__

@@ index.html.ep
% layout 'default';
% title 'pdfman';
<h3>pdfman</h3>
Examples of URLs are:
<ul>
  <li> groff(1) - <a href="<%= $c->url_for('/man')->to_abs %>/groff"
    ><%=$c->url_for('/man')->to_abs %>/groff</a></li>
  <li> groff(7) - <a href="<%= $c->url_for('/man')->to_abs %>/7/groff"
    ><%=$c->url_for('/man')->to_abs %>/7/groff</a></li>
</ul>

@@ not_found.html.ep
% layout 'default';
% title 'not found';
<h3><%= url_for() %>: not found</h3>