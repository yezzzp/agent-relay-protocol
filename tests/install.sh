#!/usr/bin/env bash
# tests/install.sh — the installer, arp-hooks and the AGENTS.md block, all against a scratch HOME.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME/.claude/skills" "$HOME/.local/bin" "$HOME/dotfiles"
pass=0; fail=0
ok() { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  ✗ %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }

printf '\ninstall.sh\n'
printf '{"env": {"ARP_QUOTA_THRESHOLD": "90"}}\n' > "$HOME/dotfiles/settings.json"
ln -s "$HOME/dotfiles/settings.json" "$HOME/.claude/settings.json"
mkdir -p "$WORK/sib/$(basename "$REPO")-extras"
ln -s "$WORK/sib/$(basename "$REPO")-extras" "$HOME/.claude/skills/mine"
# a sibling folder whose name starts with the repo's: its links are not ours
ln -s "${REPO}-extras/skill" "$HOME/.claude/skills/sibling"
printf '#!/bin/sh\necho mine\n' > "$HOME/.local/bin/arp"; chmod +x "$HOME/.local/bin/arp"
"$REPO/install.sh" --agents claude --yes >/dev/null 2>&1
[ -L "$HOME/.claude/skills/sibling" ] && ok "a link into a sibling folder is kept" || ko "a link into a sibling folder is kept" "removed"
[ ! -L "$HOME/.local/bin/arp" ] && grep -q mine "$HOME/.local/bin/arp" && ok "an existing arp that is not ours is left alone" || ko "an existing arp that is not ours is left alone" "overwritten"

printf '\narp-hooks\n'
if command -v jq >/dev/null; then
  "$REPO/bin/arp-hooks" install >/dev/null 2>&1
  [ -L "$HOME/.claude/settings.json" ] && ok "a symlinked settings.json stays a link" || ko "a symlinked settings.json stays a link" "replaced by a file"
  grep -q '"ARP_QUOTA_THRESHOLD": "90"' "$HOME/dotfiles/settings.json" && ok "a custom threshold survives install" || ko "a custom threshold survives install" "$(cat "$HOME/dotfiles/settings.json")"
  "$REPO/bin/arp-hooks" install --threshold 70 >/dev/null 2>&1
  grep -q '"ARP_QUOTA_THRESHOLD": "70"' "$HOME/dotfiles/settings.json" && ok "--threshold still sets it" || ko "--threshold still sets it" "not 70"
else
  echo "  skip: jq missing"
fi

printf '\nAGENTS.md block\n'
printf '<!-- ARP:BEGIN v2 -->\nNEW\n<!-- ARP:END -->\n' > "$WORK/blk"
printf '# Doc\nSection 8 (between ARP:BEGIN and ARP:END) is managed.\nPrecious A\n<!-- ARP:BEGIN v1 -->\nold\n<!-- ARP:END -->\nPrecious B\n' > "$WORK/a.md"
out="$(awk -v BLOCK="$WORK/blk" -f "$REPO/lib/inject.awk" "$WORK/a.md")"
[ "$(grep -c Precious <<<"$out")" = 2 ] && ok "prose that mentions the markers is kept" || ko "prose that mentions the markers is kept" "$out"
grep -q '^NEW$' <<<"$out" && ! grep -q '^old$' <<<"$out" && ok "the old block is replaced" || ko "the old block is replaced" "$out"
printf 'x\n<!-- ARP:BEGIN -->\nno end\nkeep me\n' > "$WORK/b.md"
out="$(awk -v BLOCK="$WORK/blk" -f "$REPO/lib/inject.awk" "$WORK/b.md")"
grep -q "keep me" <<<"$out" && ok "a block with no end loses nothing after it" || ko "a block with no end loses nothing after it" "$out"

printf '\nquota cut\n'
T="$WORK/proj"; mkdir -p "$T/docs/ai/tasks"
printf -- '---\ntask: a\nowner: codex\nstatus: IN_PROGRESS\n---\nx\n' > "$T/docs/ai/tasks/a.md"
printf -- '---\ntask: b\nowner: claude\nstatus: IN_PROGRESS\n---\nx\n' > "$T/docs/ai/tasks/b.md"
printf '{"cwd":"%s"}' "$T" | bash "$REPO/hooks/arp-rate-limit.sh"
grep -q 'status: IN_PROGRESS' "$T/docs/ai/tasks/a.md" && ok "another agent's task is left alone" || ko "another agent's task is left alone" "flipped"
grep -q 'status: HANDOFF' "$T/docs/ai/tasks/b.md" && ok "this agent's task is handed off" || ko "this agent's task is handed off" "not flipped"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
