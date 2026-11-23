#!/usr/bin/env bash
# tests/lessons.sh — arp lessons on a made-up memory folder.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
M="$WORK/mem"; mkdir -p "$M"
pass=0; fail=0
ok() { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  ✗ %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing «$3»" ;; esac; }
hasnt() { case "$2" in *"$3"*) ko "$1" "unexpected «$3»" ;; *) ok "$1" ;; esac; }

note() { printf -- '---\nname: %s\ndescription: %s\n---\n\n%s\n' "$1" "$2" "$3" > "$M/$1.md"; }
note rule_amounts_are_decimal "Amounts are Decimal, never float" \
  'Never use float for money in `app/services/pricing.py`; the `unit_price` column is Decimal. Same mistake happened twice.'
note gotcha_csv_dates "Dates in orders.csv come as dd/mm" \
  'Always parse `orders.csv` dates as day first; never trust the `order_date` header order.'
note rule_ids_checked "Ids are checked by the validator" \
  'Never repeat an id in `stores.csv`. The validator detects it and fails.'
note decision_dark_theme "The owner chose dark theme" 'Dark first, owner 2026-10-17.'
{ printf '# Memory\n'; for i in $(seq 1 210); do printf -- '- [Rule](rule_amounts_are_decimal.md) — line %s\n' "$i"; done; } > "$M/MEMORY.md"

printf '\nlessons\n'
out="$("$REPO/bin/arp" lessons --memory "$M")"
has   "index over 200 lines is flagged" "$out" "✗ index: 211 lines"
has   "files missing from the index are listed" "$out" "files not in the index"
has   "a lesson learned twice is a check candidate" "$out" "rule_amounts_are_decimal.md"
has   "a hard rule with anchors is enforceable" "$out" "gotcha_csv_dates.md"
has   "csv rule suggests a validator" "$out" "a validator rule"
hasnt "an already enforced rule is not proposed" "$out" "rule_ids_checked.md:"
hasnt "a plain decision is not proposed" "$out" "decision_dark_theme.md:"
"$REPO/bin/arp" lessons --memory "$M" --check >/dev/null; [ $? -eq 1 ] && ok "--check fails over the limit" || ko "--check fails over the limit" "exit 0"
head -50 "$M/MEMORY.md" > "$M/i" && mv "$M/i" "$M/MEMORY.md"
"$REPO/bin/arp" lessons --memory "$M" --check >/dev/null && ok "--check passes under the limit" || ko "--check passes under the limit" "exit 1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
