#!/usr/bin/env bash
#
# tests/run.sh — ARP hooks and installer suite, plus every other tests/*.sh.
#
# Runs the hooks with synthetic payloads against fake repos in a temporary
# directory. It does not touch your $HOME or your projects: it rewrites HOME.
# At the end it also runs every other executable tests/*.sh (not itself) and
# aggregates the exit status.
#
# Usage: tests/run.sh
# Output: 0 if everything passes, 1 if anything fails.

set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CAPTURE="$REPO/hooks/arp-plan-capture.sh"
RATELIMIT="$REPO/hooks/arp-rate-limit.sh"
ARPHOOKS="$REPO/bin/arp-hooks"
STATUSLINE="$REPO/statusline/arp-statusline.sh"
AGENTINIT="$REPO/bin/agent-init"

command -v jq >/dev/null 2>&1 || { echo "✗ jq is missing"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK:?}"' EXIT
REAL_HOME="$HOME"
export HOME="$WORK/home"   # the hooks write to $HOME/.claude/arp/relay.log
mkdir -p "$HOME/.claude"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; O=$'\033[0m'
else G=""; R=""; B=""; D=""; O=""; fi

pass=0; fail=0
ok() { printf '  %s✓%s %s\n' "$G" "$O" "$1"; pass=$((pass + 1)); }
ko() { printf '  %s✗%s %s\n      %s\n' "$R" "$O" "$1" "$2"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected «$3», got «$2»"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "does not contain «$3»" ;; esac; }
group() { printf '\n%s%s%s\n' "$B" "$1" "$O"; }

# --- helpers ------------------------------------------------------------------

# newproj <name> [branch] -> prints the path. Git repo with docs/ai/tasks/ and one commit.
newproj() {
  local d="$WORK/$1"
  mkdir -p "$d/docs/ai/tasks"
  git init -q "$d"
  git -C "$d" symbolic-ref HEAD refs/heads/main   # deterministic: main, not master
  git -C "$d" config user.email arp@test
  git -C "$d" config user.name  arp
  echo base > "$d/base.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm "chore: base"
  [ -n "${2:-}" ] && git -C "$d" checkout -qb "$2"
  printf '%s' "$d"
}

# Real payload shape, verified against one captured live: the plan travels in
# tool_response.plan and tool_input arrives EMPTY. Testing with tool_input would
# approve a hook that does not work — it already happened once.
capture() {
  jq -n --arg c "$1" --arg p "$2" \
    '{cwd:$c, session_id:"s1", hook_event_name:"PostToolUse", tool_name:"ExitPlanMode",
      tool_input:{}, tool_response:{plan:$p, isAgent:false, filePath:"/tmp/x.md"}}' | "$CAPTURE"
}
cut_()    { jq -n --arg c "$1" '{cwd:$c, hook_event_name:"StopFailure"}' | "$RATELIMIT"; }
front()   { sed -n "/^$2: /{s/^$2: //p;q;}" "$1"; }   # frontmatter key

# --- plan capture -------------------------------------------------------------

group "arp-plan-capture.sh"

# The title rules over the branch: a stage branch holds many tasks and all of
# them would end up with the same slug. The "Plan:" prefix is stripped too.
p="$(newproj cap-title phase-1-multitenant-model)"
capture "$p" '# Plan: Brand logo on the login

step one'
eq "the title rules over the branch" "$(front "$p/.arp/current-plan.md" slug)" "brand-logo-on-the-login"
has "keeps the whole plan" "$(cat "$p/.arp/current-plan.md")" "step one"

p="$(newproj cap-planning)"
capture "$p" '# Planning the accounting close'
eq "does not mangle a title that starts with «Plan»" \
   "$(front "$p/.arp/current-plan.md" slug)" "planning-the-accounting-close"

p="$(newproj cap-branch feat/Auth-Refactor)"
capture "$p" 'a plan without any heading'
eq "no title: falls back to the branch, normalized" "$(front "$p/.arp/current-plan.md" slug)" "feat-auth-refactor"

p="$(newproj cap-no-arp)"; rm -rf "${p:?}/docs"
capture "$p" '# Plan: should not be saved'
[ -e "$p/.arp" ] && ko "project without ARP: does not create .arp/" "created .arp/" || ok "project without ARP: does not create .arp/"

p="$(newproj cap-accents)"
capture "$p" '# Plan: Arreglar la exportación de PDF'
eq "transliterates accents" "$(front "$p/.arp/current-plan.md" slug)" "arreglar-la-exportacion-de-pdf"

p="$(newproj cap-no-title)"   # no title and on a trunk branch: nowhere to get one
capture "$p" 'loose text, no heading at all'
eq "no title or useful branch: fallback slug" "$(front "$p/.arp/current-plan.md" slug)" "plan"

p="$(newproj cap-garbage)"
echo 'this is not json' | "$CAPTURE"; rc=$?
eq "invalid JSON: exits 0" "$rc" "0"

p="$(newproj cap-empty)"
jq -n --arg c "$p" '{cwd:$c, tool_input:{}, tool_response:{}}' | "$CAPTURE"; rc=$?
eq "empty plan: exits 0" "$rc" "0"
[ -e "$p/.arp/current-plan.md" ] && ko "empty plan: writes no draft" "wrote one" \
                                 || ok "empty plan: writes no draft"

# Fallback in case another Claude Code version returns the plan in tool_input.
p="$(newproj cap-alt)"
jq -n --arg c "$p" '{cwd:$c, tool_input:{plan:"# Plan: through the alternate path"}}' | "$CAPTURE"
has "accepts the plan in tool_input if tool_response lacks it" \
    "$(cat "$p/.arp/current-plan.md" 2>&1)" "through the alternate path"

# A subagent in plan mode must not overwrite the main agent's plan.
p="$(newproj cap-subagent)"
capture "$p" '# Plan: the good one, from the main agent'
jq -n --arg c "$p" '{cwd:$c, tool_response:{plan:"# Plan: from a subagent", isAgent:true}}' | "$CAPTURE"
has "a subagent does not overwrite the draft" "$(cat "$p/.arp/current-plan.md")" "from the main agent"

# --- quota cut ----------------------------------------------------------------

group "arp-rate-limit.sh"

# An IN_PROGRESS task rules: it is marked HANDOFF and the draft is not even looked at.
p="$(newproj rl-inprogress)"
cat > "$p/docs/ai/tasks/active.md" <<'MD'
---
task: active
owner: claude
status: IN_PROGRESS
branch: main
updated: old
---

# Real

---

trap in the body: status: IN_PROGRESS and a loose ---
MD
capture "$p" '# Plan: draft that must not be promoted'
cut_ "$p"
eq "active task -> HANDOFF"        "$(front "$p/docs/ai/tasks/active.md" status)" "HANDOFF"
eq "active task -> owner none"     "$(front "$p/docs/ai/tasks/active.md" owner)"  "none"
eq "does not promote if there was a task" "$(ls "$p/docs/ai/tasks" | wc -l)" "1"
has "does not touch the file body" "$(cat "$p/docs/ai/tasks/active.md")" "trap in the body"

p="$(newproj rl-nothing)"
cut_ "$p"
eq "no task and no draft: writes nothing" "$(ls -A "$p/docs/ai/tasks" | wc -l)" "0"

# The case that gives all this its meaning.
p="$(newproj rl-promote fix/pdf-export)"
echo dirty > "$p/pending.txt"
capture "$p" '# Plan: Export PDF

## Steps
1. one'
cut_ "$p"
t="$p/docs/ai/tasks/export-pdf.md"   # from the title, not from the fix/pdf-export branch
[ -f "$t" ] && ok "promotes the draft to the right slug" || ko "promotes the draft to the right slug" "$t does not exist"
eq  "promoted with status HANDOFF" "$(front "$t" status)" "HANDOFF"
eq  "keeps the branch"             "$(front "$t" branch)" "fix/pdf-export"
has "carries the plan"             "$(cat "$t")" "## Steps"
has "carries the tree state"       "$(cat "$t")" "pending.txt"
has "says it is automatic"         "$(cat "$t")" "generated automatically"
[ -e "$p/.arp/current-plan.md" ] && ko "consumes the draft" "still there" || ok "consumes the draft"

cut_ "$p"   # second cut on the same thing
eq "two cuts in a row: a single task file" "$(ls "$p/docs/ai/tasks" | wc -l)" "1"

# Collision: never overwrite an existing task file.
p="$(newproj rl-collision feat/clash)"
touch "$p/docs/ai/tasks/clash.md"   # same slug the plan is going to generate
capture "$p" '# Plan: clash'
cut_ "$p"
eq "name collision: does not overwrite, adds a suffix" "$(ls "$p/docs/ai/tasks" | wc -l)" "2"

echo '' | "$RATELIMIT"; rc=$?
eq "empty payload: exits 0" "$rc" "0"

# --- hooks installer ----------------------------------------------------------

group "arp-hooks"

if ! command -v python3 >/dev/null 2>&1; then
  printf '  %sskipped: python3 is missing%s\n' "$D" "$O"
else
  export HOME="$WORK/home2"; mkdir -p "$HOME/.claude"
  s="$HOME/.claude/settings.json"
  # Settings as an old version left them: ours (legacy) next to the user's own.
  jq -n --arg r "$REPO" '{
    hooks: {
      Stop: [{hooks:[{type:"command", command:"echo mine"}]}],
      UserPromptSubmit: [{hooks:[{type:"command", command:($r + "/hooks/arp-quota-notice.sh")}]},
                         {hooks:[{type:"command", command:"echo mine-too"}]}],
      PostToolUse: [{matcher:"ExitPlanMode", hooks:[{type:"command", command:($r + "/hooks/arp-plan-capture.sh")}]}],
      StopFailure: [{matcher:"rate_limit", hooks:[{type:"command", command:($r + "/hooks/arp-rate-limit.sh")}]}]
    }}' > "$s"

  out="$("$ARPHOOKS" status 2>&1)"
  has "status reports legacy entries" "$out" "legacy entry"

  "$ARPHOOKS" install >/dev/null 2>&1
  eq "installs the statusLine" "$(jq -r '.statusLine.command' "$s")" "$REPO/statusline/arp-statusline.sh"
  eq "removes the legacy PostToolUse" "$(jq -r '.hooks.PostToolUse // "none"' "$s")" "none"
  eq "removes the legacy StopFailure" "$(jq -r '.hooks.StopFailure // "none"' "$s")" "none"
  eq "removes only our UserPromptSubmit entry" \
     "$(jq -r '[.hooks.UserPromptSubmit[].hooks[].command] | join(",")' "$s")" "echo mine-too"
  eq "keeps the user's own hooks" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" "echo mine"
  eq "registers none of the three hooks (the plugin does)" \
     "$(jq -r '[.hooks.PostToolUse, .hooks.StopFailure] | map(select(. != null)) | length' "$s")" "0"
  eq "leaves a backup" "$(ls "$HOME/.claude"/settings.json.arp-bak-* 2>/dev/null | wc -l | tr -d ' ')" "1"

  out="$("$ARPHOOKS" status 2>&1)"
  has "status reports the plugin as source" "$out" "from the plugin"

  before="$(cat "$s")"
  "$ARPHOOKS" install >/dev/null 2>&1
  eq "idempotent: second install changes nothing" "$(cat "$s")" "$before"

  "$ARPHOOKS" uninstall >/dev/null 2>&1
  eq "uninstall respects foreign hooks" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" "echo mine"
  eq "uninstall removes the statusLine" "$(jq -r '.statusLine // "none"' "$s")" "none"
fi

# --- statusline ---------------------------------------------------------------

group "arp-statusline.sh"

export HOME="$WORK/home3"; mkdir -p "$HOME/.claude" "$WORK/fakebin"
payload='{"model":{"display_name":"M"},"cwd":"/tmp","context_window":{"used_percentage":5}}'
strip() { sed 's/\x1b\[[0-9;]*m//g'; }

out="$(printf '%s' "$payload" | "$STATUSLINE" | strip)"
case "$out" in *sessions*) ko "no arp sessions command: segment hidden" "$out" ;; *) ok "no arp sessions command: segment hidden" ;; esac

printf '#!/bin/sh\necho 2/3\n' > "$WORK/fakebin/arp"; chmod +x "$WORK/fakebin/arp"
rm -rf "$HOME/.claude/arp"
out="$(printf '%s' "$payload" | PATH="$WORK/fakebin:$PATH" "$STATUSLINE" | strip)"
has "shows the sessions segment" "$out" "sessions 2/3"

printf '#!/bin/sh\necho 5/3\n' > "$WORK/fakebin/arp"
out="$(printf '%s' "$payload" | PATH="$WORK/fakebin:$PATH" "$STATUSLINE" | strip)"
has "caches the count for 30 s" "$out" "sessions 2/3"

printf '#!/bin/sh\nexit 1\n' > "$WORK/fakebin/arp"
rm -rf "$HOME/.claude/arp"
out="$(printf '%s' "$payload" | PATH="$WORK/fakebin:$PATH" "$STATUSLINE" | strip)"
case "$out" in *sessions*) ko "failing command: segment hidden" "$out" ;; *) ok "failing command: segment hidden" ;; esac

# --- agent-init (deterministic part) ------------------------------------------

group "agent-init --no-agent"

export HOME="$WORK/home4"; mkdir -p "$HOME"
p="$(newproj init-fresh)"; touch "$p/uv.lock"; git -C "$p" branch develop
( cd "$p" && "$AGENTINIT" --no-agent >/dev/null 2>&1 )
[ -f "$p/.arp/config.toml" ] && ok "writes .arp/config.toml" || ko "writes .arp/config.toml" "missing"
[ -f "$p/.arp/flows.toml" ] && ok "writes .arp/flows.toml" || ko "writes .arp/flows.toml" "missing"
has "detects the stack command" "$(cat "$p/.arp/config.toml")" "uv run pytest"
has "detects the integration branch" "$(cat "$p/.arp/config.toml")" 'integration = "develop"'
has "leaves TODO for what it cannot detect" "$(cat "$p/.arp/config.toml")" 'e2e      = "TODO"'
if python3 -c 'import tomllib,sys; [tomllib.load(open(f,"rb")) for f in sys.argv[1:]]' \
     "$p/.arp/config.toml" "$p/.arp/flows.toml" 2>/dev/null; then ok "both files are valid TOML"
else ko "both files are valid TOML" "tomllib failed"; fi
has "gitignore keeps config.toml tracked" "$(cat "$p/.gitignore")" "!.arp/config.toml"
has "gitignore keeps the test-guard baseline tracked" "$(cat "$p/.gitignore")" "!.arp/test-guard-baseline.json"
has "config.toml offers integrate.after, commented" "$(cat "$p/.arp/config.toml")" "# after = [\"git push origin develop\"]"
has "AGENTS.md has the working charter section" "$(cat "$p/AGENTS.md")" "## Working charter"

echo 'quick = "mine"' > "$p/.arp/config.toml"
( cd "$p" && "$AGENTINIT" --no-agent >/dev/null 2>&1 )
eq "never rewrites an existing config.toml" "$(cat "$p/.arp/config.toml")" 'quick = "mine"'

p="$(newproj init-dry)"
( cd "$p" && "$AGENTINIT" --dry-run >/dev/null 2>&1 )
[ -e "$p/.arp" ] && ko "--dry-run writes nothing" "created .arp/" || ok "--dry-run writes nothing"

# --- installer ----------------------------------------------------------------

group "install.sh"

export HOME="$WORK/home5"; mkdir -p "$HOME/.claude/skills" "$HOME/.agents"
ln -s "$REPO/skills/commit" "$HOME/.claude/skills/commit"       # old link into this repo
ln -s "$REPO/skills/relay"  "$HOME/.claude/skills/relay"
mkdir -p "$WORK/other-skill"; ln -s "$WORK/other-skill" "$HOME/.claude/skills/other"
mkdir -p "$HOME/.claude/skills/real-dir"
"$REPO/install.sh" --agents codex >/dev/null 2>&1
[ -e "$HOME/.claude/skills/commit" ] || [ -L "$HOME/.claude/skills/commit" ] \
  && ko "removes old links into the repo from ~/.claude/skills" "commit link still there" \
  || ok "removes old links into the repo from ~/.claude/skills"
[ -L "$HOME/.claude/skills/other" ] && [ -d "$HOME/.claude/skills/real-dir" ] \
  && ok "touches nothing else in ~/.claude/skills" || ko "touches nothing else in ~/.claude/skills" "something was removed"
[ -L "$HOME/.agents/skills/commit" ] && ok "links the skills for Codex" || ko "links the skills for Codex" "no commit link"
[ -L "$HOME/.local/bin/arp-hooks" ] && ok "links the binaries" || ko "links the binaries" "arp-hooks not linked"

# --- other suites -------------------------------------------------------------

export HOME="$REAL_HOME"
others=0
for t in "$REPO"/tests/*.sh; do
  [ -x "$t" ] || continue
  [ "$(readlink -f "$t")" = "$(readlink -f "${BASH_SOURCE[0]}")" ] && continue
  group "$(basename "$t")"
  others=$((others + 1))
  if "$t"; then ok "suite $(basename "$t")"; else ko "suite $(basename "$t")" "exited non-zero"; fi
done
[ "$others" -gt 0 ] || printf '\n  %sno other suites found%s\n' "$D" "$O"

# --- result -------------------------------------------------------------------

printf '\n%s%d passed, %d failed%s\n' "$B" "$pass" "$fail" "$O"
[ "$fail" -eq 0 ]
