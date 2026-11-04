#!/usr/bin/env bash
# Prints the "## [<version>]" section of CHANGELOG.md as an HTML fragment for
# Sparkle's update dialog (no <html>/<body>, so generate_appcast embeds it).
#
# Usage: scripts/changelog-to-html.sh <version> [changelog]
#
# Handles the Markdown CHANGELOG.md uses: ###/#### headings, "-"/"*" lists
# with one nested level, paragraphs, **bold**, `code` and [links](url).
# Uses only perl, which ships with macOS. Exits 1 if the section is missing.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:?Usage: $0 <version> [changelog]}"
CHANGELOG="${2:-${PROJECT_ROOT}/CHANGELOG.md}"

SECTION="$(awk -v ver="$VERSION" '
  index($0, "## [" ver "]") == 1 { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$CHANGELOG")"

if [[ -z "${SECTION//[[:space:]]/}" ]]; then
  echo "No \"## ${VERSION}\" section in ${CHANGELOG}." >&2
  exit 1
fi

printf '%s\n' "$SECTION" | perl -e '
  use strict;
  use warnings;
  binmode STDIN, ":encoding(UTF-8)";
  binmode STDOUT, ":encoding(UTF-8)";

  my @out;
  my $depth = 0;      # open <ul> levels (0..2)
  my $item_open = 0;  # an <li> is open at the current depth
  my @para;

  sub inline {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    my @code;
    $s =~ s/`([^`]+)`/push @code, $1; "\x00" . $#code . "\x00"/ge;
    $s =~ s/\*\*(.+?)\*\*/<strong>$1<\/strong>/g;
    $s =~ s/\[([^\]]+)\]\(([^)\s]+)\)/<a href="$2">$1<\/a>/g;
    $s =~ s/\x00(\d+)\x00/<code>$code[$1]<\/code>/g;
    return $s;
  }
  sub flush_para {
    push @out, "<p>" . join(" ", map { inline($_) } @para) . "</p>" if @para;
    @para = ();
  }
  sub close_lists {
    my ($to) = @_;
    while ($depth > $to) {
      push @out, "</li>" if $item_open;
      push @out, "</ul>";
      $depth--;
      $item_open = 1 if $depth > 0;
    }
    if ($depth == 0) { $item_open = 0; }
  }

  while (my $line = <STDIN>) {
    chomp $line;
    if ($line =~ /^\s*$/) {
      flush_para();
      next;
    }
    if ($line =~ /^(#{3,4})\s+(.*)$/) {
      flush_para();
      close_lists(0);
      my $level = length($1);
      push @out, "<h$level>" . inline($2) . "</h$level>";
      next;
    }
    if ($line =~ /^(\s*)[-*]\s+(.*)$/) {
      flush_para();
      my $want = length($1) >= 2 ? 2 : 1;
      $want = $depth + 1 if $want > $depth + 1;
      if ($want > $depth) {
        push @out, "<ul>";
        $depth = $want;
      } else {
        close_lists($want);
        push @out, "</li>" if $item_open;
      }
      push @out, "<li>" . inline($2);
      $item_open = 1;
      next;
    }
    if ($depth > 0 && $line =~ /^\s+(\S.*)$/) {
      $out[-1] .= " " . inline($1);
      next;
    }
    close_lists(0);
    push @para, $line;
  }
  flush_para();
  close_lists(0);
  print join("\n", @out), "\n";
'
