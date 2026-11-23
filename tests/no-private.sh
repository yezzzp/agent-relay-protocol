#!/usr/bin/env bash
#
# tests/no-private.sh — fails if a tracked file contains a private term.
#
# The denylist is read from $AGENT_CORE_DENYLIST or, if unset,
# ~/.config/agent-core/denylist.txt: one case-insensitive term per line (blank
# lines and lines starting with # are ignored). The list itself NEVER lives in
# this repo. With no denylist, the test skips with a note and exits 0.

set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LIST="${AGENT_CORE_DENYLIST:-$HOME/.config/agent-core/denylist.txt}"

if [ ! -r "$LIST" ]; then
  echo "  skipped: no denylist (set AGENT_CORE_DENYLIST or create ~/.config/agent-core/denylist.txt)"
  exit 0
fi

terms="$(grep -vE '^[[:space:]]*(#|$)' "$LIST" || true)"
if [ -z "$terms" ]; then
  echo "  skipped: the denylist is empty"
  exit 0
fi

fail=0
while IFS= read -r term; do
  [ -n "$term" ] || continue
  hits="$(git -C "$REPO" grep -nIiF -e "$term" -- . 2>/dev/null || true)"
  names="$(git -C "$REPO" ls-files | grep -iF -e "$term" || true)"
  if [ -n "$hits$names" ]; then
    fail=1
    # Never print the term itself: a CI log is public too.
    echo "  ✗ a denylist term matches in tracked files:"
    [ -n "$hits" ] && printf '%s\n' "$hits" | cut -d: -f1,2 | sed 's/^/      /'
    [ -n "$names" ] && printf '%s\n' "$names" | sed 's/^/      (file name) /'
  fi
done <<< "$terms"

if [ "$fail" -eq 0 ]; then echo "  ✓ no denylist term found in tracked files"; fi
exit "$fail"
