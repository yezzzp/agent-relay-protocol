#!/usr/bin/env bash
#
# PostToolUse hook (matcher: ExitPlanMode) — captures the approved plan.
#
# Claude Code's native plan mode lives only in the conversation: the plan is the
# argument of a tool call and never touches the disk. If the session is cut off,
# it is lost entirely. This hook persists it to .arp/current-plan.md.
#
# It is a disposable DRAFT, not a task file:
#   - all goes well   -> the next plan overwrites it; docs/ai/tasks/ stays empty
#   - you run /relay  -> the skill reads it and writes the real task file
#   - quota runs out  -> arp-rate-limit.sh promotes it to docs/ai/tasks/ as HANDOFF
#
# PostToolUse only fires when the tool succeeded, so a plan rejected by the user
# never gets here. It costs zero tokens: it does not enter the context. It never
# fails: it always exits 0.

set -uo pipefail

payload="$(cat)"
LOG="$HOME/.claude/arp/relay.log"
mkdir -p "$(dirname "$LOG")"

command -v jq >/dev/null 2>&1 || exit 0

CWD="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="$PWD"

# Only in projects with ARP initialized. In any other, creating .arp/ would dirty
# the tree with a directory its .gitignore does not know.
[ -d "$CWD/docs/ai/tasks" ] || exit 0

# A subagent leaving plan mode brings its own partial plan. Capturing it would
# overwrite the main agent's, which is the one that represents the task.
[ "$(printf '%s' "$payload" | jq -r '.tool_response.isAgent // false' 2>/dev/null)" = "true" ] && exit 0

# The plan arrives in tool_response.plan — verified against the real payload, not
# the documentation: there tool_input comes empty. tool_input.plan stays as a
# fallback in case another version moves it.
PLAN="$(printf '%s' "$payload" | jq -r '.tool_response.plan // .tool_input.plan // empty' 2>/dev/null)"
if [ -z "$PLAN" ]; then
  # Do not write the plan off without a trace: the raw payload stays at hand to
  # see what shape it really has.
  printf '%s' "$payload" > "$HOME/.claude/arp/last-unparsed-payload.json" 2>/dev/null
  printf '%s approved plan without content in %s (payload in ~/.claude/arp/last-unparsed-payload.json)\n' \
         "$(date -Is)" "$CWD" >> "$LOG"
  exit 0
fi

SESSION="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null)"
NOW="$(date -Is)"

# Slug: the plan title rules, the branch is the fallback. The title describes the
# TASK; the branch describes the line of work, and a stage branch
# (`phase-1-multitenant-model`) holds many tasks that would collide. It is computed
# here once so arp-rate-limit.sh does not have to guess it in the middle of a cut.
slugify() {
  local out
  if out="$(printf '%s' "$1" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null)"; then
    printf '%s' "$out"
  else
    printf '%s' "$1"   # without iconv: accents are dropped by norm()'s sed
  fi
}

norm() {
  slugify "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' \
    | cut -c1-50
}

TITLE="$(printf '%s\n' "$PLAN" | grep -m1 -E '^#+[[:space:]]+' | sed -E 's/^#+[[:space:]]+//')"
# "# Plan: export PDF" -> "export PDF". The colon is required so a title that
# merely starts with "Planning" is not mangled.
TITLE="$(printf '%s' "$TITLE" | sed -E 's/^[[:space:]]*[Pp][Ll][Aa][Nn][[:space:]]*:[[:space:]]*//')"
SLUG="$(norm "$TITLE")"

if [ -z "$SLUG" ]; then
  case "$BRANCH" in
    ''|main|master|develop|dev|trunk|HEAD) ;;
    *) SLUG="$(norm "$BRANCH")" ;;
  esac
fi
[ -n "$SLUG" ] || SLUG="plan"

DRAFT_DIR="$CWD/.arp"
DRAFT="$DRAFT_DIR/current-plan.md"
mkdir -p "$DRAFT_DIR" || exit 0

# Atomic write: the cut can arrive right here.
tmp="$DRAFT.arp-tmp"
{
  printf -- '---\n'
  printf 'slug: %s\n'    "$SLUG"
  printf 'branch: %s\n'  "${BRANCH:-none}"
  printf 'session: %s\n' "${SESSION:-none}"
  printf 'captured: %s\n' "$NOW"
  printf -- '---\n\n'
  printf '%s\n' "$PLAN"
} > "$tmp" && mv "$tmp" "$DRAFT"

printf '%s plan captured — %s (slug: %s)\n' "$NOW" "$DRAFT" "$SLUG" >> "$LOG"
exit 0
