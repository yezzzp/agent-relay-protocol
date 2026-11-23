#!/usr/bin/env bash
#
# StopFailure hook (matcher: rate_limit) — the axe has already fallen.
#
# When the turn dies because the quota ran out, marks the project's active task
# as HANDOFF so the other agent finds it with `resume`.
#
# If there is no active task, promotes the draft left by arp-plan-capture.sh
# (.arp/current-plan.md) to docs/ai/tasks/<slug>.md. Without that, work done in
# native plan mode would be lost entirely: the plan only lives in the conversation.
#
# StopFailure is non-blocking: its output and exit code are ignored. It is only
# good for side effects — which is exactly what we need.

set -uo pipefail

payload="$(cat)"
LOG="$HOME/.claude/arp/relay.log"
mkdir -p "$(dirname "$LOG")"

if command -v jq >/dev/null 2>&1; then
  CWD="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
else
  CWD="$(printf '%s' "$payload" | python3 -I -c 'import json,sys
try: print(json.load(sys.stdin).get("cwd") or "")
except Exception: pass' 2>/dev/null)"
fi
[ -n "$CWD" ] || CWD="$PWD"

TASKS="$CWD/docs/ai/tasks"
[ -d "$TASKS" ] || { printf '%s quota cut in %s (no docs/ai/tasks)\n' "$(date -Is)" "$CWD" >> "$LOG"; exit 0; }

NOW="$(date -Is)"
touched=0

for f in "$TASKS"/*.md; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in _TEMPLATE.md) continue ;; esac
  grep -qE '^status:[[:space:]]*IN_PROGRESS' "$f" || continue
  # Only this agent's own tasks: a task another agent owns is not ours to hand off.
  owner="$(awk 'NR==1 && $0=="---" {fm=1; next} fm && $0=="---" {exit} fm && /^owner:/ {sub(/^owner:[[:space:]]*/, ""); print; exit}' "$f")"
  case "$owner" in claude|none|"") ;; *) continue ;; esac

  # Only inside the frontmatter (between the first pair of ---), never in the body.
  awk -v now="$NOW" '
    NR==1 && $0=="---" { infm=1; print; next }
    infm && $0=="---"  { infm=0; print; next }
    infm && /^status:/  { print "status: HANDOFF"; next }
    infm && /^owner:/   { print "owner: none";     next }
    infm && /^updated:/ { print "updated: " now;   next }
    { print }
  ' "$f" > "$f.arp-tmp" && mv "$f.arp-tmp" "$f"

  printf '%s quota cut — %s marked HANDOFF\n' "$NOW" "$f" >> "$LOG"
  touched=$((touched + 1))
done

[ "$touched" -eq 0 ] || exit 0

# No active task: the work may have come from native plan mode, which writes
# nothing to disk. arp-plan-capture.sh leaves the approved plan there; this is the
# only branch where that draft becomes a task file.
DRAFT="$CWD/.arp/current-plan.md"
if [ ! -r "$DRAFT" ]; then
  printf '%s quota cut in %s (no IN_PROGRESS task, no draft)\n' "$NOW" "$CWD" >> "$LOG"
  exit 0
fi

fm() {   # reads a key from the draft's frontmatter, never from the body
  awk -v k="$1" '
    NR==1 && $0=="---" { infm=1; next }
    infm && $0=="---"  { exit }
    infm && index($0, k ": ")==1 { print substr($0, length(k)+3); exit }
  ' "$DRAFT"
}

SLUG="$(fm slug)"; [ -n "$SLUG" ] || SLUG="plan"
BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null)"
[ -n "$BRANCH" ] || BRANCH="$(fm branch)"

TARGET="$TASKS/$SLUG.md"
# Do not overwrite an existing task (e.g. one already DONE with the same slug).
[ -e "$TARGET" ] && TARGET="$TASKS/$SLUG-$(date +%Y%m%d%H%M%S).md"

{
  printf -- '---\n'
  printf 'task: %s\n'    "$SLUG"
  printf 'owner: none\n'
  printf 'status: HANDOFF\n'
  printf 'branch: %s\n'  "${BRANCH:-none}"
  printf 'updated: %s\n' "$NOW"
  printf -- '---\n\n'
  cat <<'EOF'
> **Task file generated automatically by ARP** when the quota ran out in the
> middle of a turn. It holds the plan that was approved, **not** the decisions made
> while executing it: the cut was abrupt and nobody got to write them.
>
> Rebuild the real state with `git log` and `git diff`, and run the verify
> command before writing code (skill `resume`).
EOF
  # The capture date gives away an old draft: if the plan is days old, it may
  # already have been finished and this is noise. Let the reader judge.
  CAPTURED="$(fm captured)"
  [ -n "$CAPTURED" ] && printf '>\n> Plan approved on %s. Cut: %s.\n' "$CAPTURED" "$NOW"

  printf '\n## Approved plan\n\n'
  # Draft body: everything after the frontmatter.
  awk 'NR==1 && $0=="---"      { infm=1; next }
       infm && $0=="---"       { infm=0; body=1; next }
       body && !seen && $0==""  { next }          # no extra blank line
       body                     { seen=1; print }' "$DRAFT"

  printf '\n## Tree state at the cut\n\n'
  printf 'Branch: `%s`\n\n' "${BRANCH:-unknown}"

  printf 'Uncommitted:\n\n```\n'
  git -C "$CWD" status --porcelain 2>/dev/null | head -50 || true
  printf '```\n\n'

  printf 'Latest commits:\n\n```\n'
  git -C "$CWD" log --oneline -10 2>/dev/null || true
  printf '```\n'
} > "$TARGET.arp-tmp" && mv "$TARGET.arp-tmp" "$TARGET" || {
  printf '%s quota cut — could not write %s; the draft is kept\n' "$NOW" "$TARGET" >> "$LOG"
  exit 0
}

# The draft is consumed: it is a task file now. Otherwise a second cut on the
# same task would promote it again and leave a duplicate.
rm -f "$DRAFT"

printf '%s quota cut — draft promoted to %s (HANDOFF)\n' "$NOW" "$TARGET" >> "$LOG"
exit 0
