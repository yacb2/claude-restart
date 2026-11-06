#!/bin/sh
# Public-repo guard (BL-091): no tracked file may carry a term from the private
# denylist (a confidential client's names). The list lives OUTSIDE the repo, one
# case-insensitive ERE per line, `#` lines are comments:
#   ${HANDOFF_PRIVATE_TERMS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/handoff-private-terms}
# Output names file:line only, never the matched text. No list file: SKIP, exit 0.
# The control positive scans a temp repo with a synthetic term, proving the scan fails.
set -u

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT

# scan <repo> <denylist>: prints file:line of each match, returns 0 when clean.
scan() {
  grep -v '^[[:space:]]*#' "$2" | grep -v '^[[:space:]]*$' > "$TMP/terms" || true
  [ -s "$TMP/terms" ] || return 0
  hits="$(cd "$1" && git grep -nIiE -f "$TMP/terms" 2>/dev/null | cut -d: -f1,2)"
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits"
  return 1
}

# Control positive: a synthetic term in a temp repo must be caught, and must not be echoed.
CP="$TMP/cp"
mkdir "$CP" && git -C "$CP" init -q && printf 'a line\nthe zq9synthetic term\n' > "$CP/f.txt" && git -C "$CP" add f.txt
printf '# comment\n\nzq9SYNTHETIC\n' > "$TMP/cp-terms"
out="$(scan "$CP" "$TMP/cp-terms")" && rc=0 || rc=$?
if [ "$rc" = 1 ] && [ "$out" = "f.txt:2" ]; then
  ok "control positive: a synthetic term is caught and reported as file:line only"
else
  no "control positive: scan returned $rc with output '$out' (want 1, 'f.txt:2')"
fi

LIST="${HANDOFF_PRIVATE_TERMS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/handoff-private-terms}"
if [ ! -f "$LIST" ]; then
  printf 'SKIP - no denylist at %s\n' "$LIST"
else
  out="$(scan "$ROOT" "$LIST")" && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    ok "no tracked file carries a denylisted term"
  else
    no "tracked files carry denylisted terms (file:line only):"
    printf '%s\n' "$out"
  fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
