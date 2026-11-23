#!/usr/bin/env bash
#
# tests/session-start.sh — adoption registry and the session-start hook.
# Runs against throwaway repos with a temporary HOME and database.

set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ARP="$REPO/bin/arp"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AGENT_CORE_DB="$WORK/db.sqlite" XDG_CACHE_HOME="$WORK/cache" \
       AGENT_CORE_CONFIG_HOME="$WORK/config"
mkdir -p "$HOME" "$AGENT_CORE_CONFIG_HOME"

pass=0; fail=0
ok() { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  ✗ %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing «$3»" ;; esac; }
hasnt() { case "$2" in *"$3"*) ko "$1" "unexpected «$3»" ;; *) ok "$1" ;; esac; }

newrepo() {
  local d="$WORK/$1"; mkdir -p "$d"; git init -q "$d"
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  printf '%s' "$d"
}
hook() { printf '{"cwd":"%s","source":"%s"}' "$1" "${2:-startup}" | "$ARP" session-start; }
in_repo() { (cd "$1" && shift && "$ARP" "$@"); }

printf '\nsession-start\n'

r="$(newrepo advanced)"
printf '# Rules\nWe use worktrees.\n' > "$r/CLAUDE.md"
out="$(hook "$r")"
has   "first visit asks once" "$out" "first visit to this project"
has   "audit sees the existing CLAUDE.md" "$out" "already describes a workflow"

in_repo "$r" decline >/dev/null
out="$(hook "$r")"
[ -z "$out" ] && ok "declined: nothing injected" || ko "declined: nothing injected" "got output"

in_repo "$r" adopt --state partial --pieces tests,ui-check >/dev/null
out="$(hook "$r")"
has   "partial: tests section" "$out" "## Tests: decide before the code"
hasnt "partial: no integration section" "$out" "## Integration"

in_repo "$r" adopt >/dev/null
out="$(hook "$r")"
has   "adopted: full workflow" "$out" "## Integration"
has   "adopted: no config hint" "$out" "No \`.arp/config.toml\` yet"

mkdir -p "$r/.arp" "$r/docs/ai/tasks"
printf '[verify]\nquick = "make check"\n' > "$r/.arp/config.toml"
printf '[checkout]\nsays = "pay"\n' > "$r/.arp/flows.toml"
cat > "$r/docs/ai/tasks/pay.md" <<'EOF'
---
task: pay
owner: claude
status: IN_PROGRESS
---
## Specs
S1. «Nothing repeated on the receipt.»
## Tasks
- [x] model
- [ ] receipt view
EOF
out="$(hook "$r")"
has   "project commands come from the config" "$out" "quick: \`make check\`"
has   "flows are listed" "$out" "user flows: checkout"
has   "active task and next step" "$out" "Next: receipt view"
hasnt "specs only after compaction" "$out" "Nothing repeated on the receipt"
out="$(hook "$r" compact)"
has   "compaction reprints the owner's words" "$out" "Nothing repeated on the receipt"

in_repo "$r" audit >/dev/null
has   "audit resets to asking" "$(hook "$r")" "first visit to this project"

# periodic test-health report: due on first run, then every report_every_days
r4="$(newrepo reported)"
(cd "$r4" && "$ARP" adopt >/dev/null)
cat > "$WORK/junit.xml" <<'X'
<testsuite name="s" tests="2"><testcase classname="t" name="a" file="t.py" time="0.1"/><testcase classname="t" name="b" file="t.py" time="0.2"><failure message="x"/></testcase></testsuite>
X
(cd "$r4" && "$ARP" test-record --tier unit --runner session --junit "$WORK/junit.xml" >/dev/null)
hook "$r4" >/dev/null
for i in $(seq 1 30); do [ -f "$WORK/reports/reported/latest.json" ] && break; sleep 0.2; done
[ -f "$WORK/reports/reported/latest.json" ] && ok "a due report is written in the background" || ko "a due report is written in the background" "no latest.json"
ls "$WORK"/reports/reported/test-health-*.html >/dev/null 2>&1 && ok "the report page exists" || ko "the report page exists" "no html"
has   "the next session mentions the report" "$(hook "$r4")" "## Test health ("
before="$(stat -c %Y "$WORK/reports/reported/latest.json")"
hook "$r4" >/dev/null; sleep 1
[ "$before" = "$(stat -c %Y "$WORK/reports/reported/latest.json")" ] && ok "not due again the same day" || ko "not due again the same day" "rewritten"

printf 'default = "off"\n' > "$AGENT_CORE_CONFIG_HOME/config.toml"
r2="$(newrepo quiet)"
[ -z "$(hook "$r2")" ] && ok "default off: a new repo is never asked" || ko "default off" "got output"

printf 'default = "on"\n' > "$AGENT_CORE_CONFIG_HOME/config.toml"
r3="$(newrepo eager)"
has   "default on: adopted at once" "$(hook "$r3")" "## Every task"

rm "$AGENT_CORE_CONFIG_HOME/config.toml"
mkdir -p "$WORK/empty"
has   "outside git: suggests git init and agent-init" "$(hook "$WORK/empty")" "agent-init"

printf '{"cwd": broken' | "$ARP" session-start >/dev/null 2>&1 && ok "bad payload never fails the session" \
  || ko "bad payload never fails the session" "non-zero exit"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
