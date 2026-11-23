#!/usr/bin/env bash
#
# Agent Relay Protocol — installer
#
# Claude Code gets skills, hooks and commands from the agent-core plugin:
#   /plugin marketplace add yezzzp/agent-relay-protocol
#   /plugin install agent-core@agent-core
# This script only does what a plugin cannot:
#   - links agent-init, arp and arp-hooks into ~/.local/bin
#   - links the skills into ~/.agents/skills for Codex
#   - installs the statusline (quota bridge) for Claude Code
#   - removes the old skill links this repo used to put in ~/.claude/skills
# Everything is a symlink, so a `git pull` in this repo updates it all.
#
# Usage:
#   ./install.sh                       interactive selector
#   ./install.sh --agents claude,codex non-interactive
#   ./install.sh --all --yes           everything detected, no questions
#   ./install.sh --uninstall           remove the links

set -euo pipefail

# The repo stays where you cloned it and is the installation: everything is
# symlinked from here, so what you edit takes effect immediately.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SKILLS_SRC="$REPO_DIR/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
CODEX_SKILLS="$HOME/.agents/skills"

# --- targets: label | what it gets | command that detects it -----------------
TARGET_KEYS=(claude codex)
TARGET_LABEL=("Claude Code" "Codex CLI")
TARGET_DESC=("statusline + plugin" "$CODEX_SKILLS")
TARGET_BIN=(claude codex)

STATES=() ; AVAIL=() ; CUR=0
ASSUME_YES=0 ; PICK_ALL=0 ; UNINSTALL=0 ; PRESELECT=""

C_DIM=$'\033[2m' ; C_OK=$'\033[32m' ; C_WARN=$'\033[33m'
C_ERR=$'\033[31m' ; C_BOLD=$'\033[1m' ; C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }

usage() { sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# remove_repo_links <dir> <label> — removes symlinks in <dir> that point into this
# repo. Never touches anything else: not real folders, not other people's links.
remove_repo_links() {
  local dir="$1" label="$2" link
  [ -d "$dir" ] || return 0
  for link in "$dir"/*; do
    [ -L "$link" ] || continue
    if [[ "$(readlink "$link")" == "$REPO_DIR"* ]]; then
      rm -f "${link:?}"; ok "$label: removed $(basename "$link")"
    fi
  done
}

# --- arguments ---------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --agents)    PRESELECT="${2:-}"; shift 2 ;;
    --agents=*)  PRESELECT="${1#*=}"; shift ;;
    --all)       PICK_ALL=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage ;;
    *)           err "Unknown option: $1"; usage ;;
  esac
done

# --- uninstall ---------------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  say "${C_BOLD}Removing ARP links...${C_OFF}"
  if command -v jq >/dev/null 2>&1; then
    "$REPO_DIR/bin/arp-hooks" uninstall 2>/dev/null || true
  fi
  for c in agent-init arp arp-hooks; do
    if [ -L "$BIN_DIR/$c" ]; then rm -f "${BIN_DIR:?}/${c:?}"; ok "$c"; fi
  done
  remove_repo_links "$CLAUDE_SKILLS" "Claude Code"
  remove_repo_links "$CODEX_SKILLS" "Codex CLI"
  rm -f "${HOME:?}/.claude/arp/targets"
  say "Done. The plugin is removed from inside Claude Code: /plugin uninstall agent-core"
  exit 0
fi

# --- dependencies ------------------------------------------------------------
say "${C_BOLD}Agent Relay Protocol${C_OFF} ${C_DIM}· $REPO_DIR${C_OFF}"
say ""
say "${C_BOLD}Dependencies${C_OFF}"

command -v git >/dev/null 2>&1 && ok "git" || warn "git not found (agent-init needs it)"

HAS_UV=0
if command -v uv >/dev/null 2>&1; then HAS_UV=1; ok "uv"
else warn "uv not found ${C_DIM}— needed for Graphify${C_OFF}"; fi

for i in "${!TARGET_KEYS[@]}"; do
  if command -v "${TARGET_BIN[$i]}" >/dev/null 2>&1; then
    AVAIL[$i]=1; STATES[$i]=1; ok "${TARGET_LABEL[$i]}"
  else
    AVAIL[$i]=0; STATES[$i]=0; warn "${TARGET_LABEL[$i]} not found"
  fi
done
say ""

# --- selection ---------------------------------------------------------------
apply_preselect() {
  local k found
  for i in "${!TARGET_KEYS[@]}"; do STATES[$i]=0; done
  IFS=',' read -ra _sel <<< "$PRESELECT"
  for k in "${_sel[@]}"; do
    found=0
    for i in "${!TARGET_KEYS[@]}"; do
      if [ "${TARGET_KEYS[$i]}" = "$k" ]; then STATES[$i]=1; found=1; fi
    done
    if [ "$found" -eq 0 ]; then err "Unknown agent: $k"; exit 1; fi
  done
  return 0
}

draw_menu() {
  local i cursor mark line
  for i in "${!TARGET_KEYS[@]}"; do
    cursor="  " ; mark=" "
    [ "$i" -eq "$CUR" ] && cursor="❯ "
    [ "${STATES[$i]}" -eq 1 ] && mark="x"
    line=$(printf '%s[%s] %-13s %s' "$cursor" "$mark" "${TARGET_LABEL[$i]}" "${TARGET_DESC[$i]}")
    if [ "${AVAIL[$i]}" -eq 0 ]; then
      printf '%s%s  (not detected)%s\n' "$C_DIM" "$line" "$C_OFF"
    else
      printf '%s\n' "$line"
    fi
  done
}

tui_select() {
  local key rest
  printf '%sInstall ARP for:%s\n\n' "$C_BOLD" "$C_OFF"
  tput civis 2>/dev/null || true
  stty -echo < /dev/tty 2>/dev/null || true
  # Restore the terminal no matter what: without this, a Ctrl-C leaves the
  # terminal without echo and with a hidden cursor.
  trap 'tput cnorm 2>/dev/null; stty echo < /dev/tty 2>/dev/null; printf "\n"' EXIT INT TERM

  draw_menu
  printf '\n%s↑↓ move · space toggle · enter confirm · q cancel%s' "$C_DIM" "$C_OFF"

  while true; do
    IFS= read -rsn1 key < /dev/tty
    case "$key" in
      $'\x1b')  # arrows arrive as ESC [ A/B
        read -rsn2 -t 0.05 rest < /dev/tty || true
        case "$rest" in
          '[A') CUR=$(( (CUR - 1 + ${#TARGET_KEYS[@]}) % ${#TARGET_KEYS[@]} )) ;;
          '[B') CUR=$(( (CUR + 1) % ${#TARGET_KEYS[@]} )) ;;
        esac ;;
      k) CUR=$(( (CUR - 1 + ${#TARGET_KEYS[@]}) % ${#TARGET_KEYS[@]} )) ;;
      j) CUR=$(( (CUR + 1) % ${#TARGET_KEYS[@]} )) ;;
      ' ') STATES[$CUR]=$(( 1 - STATES[CUR] )) ;;
      q|Q) trap - EXIT INT TERM; tput cnorm 2>/dev/null; stty echo < /dev/tty 2>/dev/null
           printf '\n\nCancelled.\n'; exit 0 ;;
      '')  break ;;
    esac
    printf '\r'
    tput cuu $(( ${#TARGET_KEYS[@]} + 1 )) 2>/dev/null
    tput ed 2>/dev/null
    draw_menu
    printf '\n%s↑↓ move · space toggle · enter confirm · q cancel%s' "$C_DIM" "$C_OFF"
  done

  trap - EXIT INT TERM
  tput cnorm 2>/dev/null || true
  stty echo < /dev/tty 2>/dev/null || true
  printf '\n\n'
}

if [ -n "$PRESELECT" ]; then
  apply_preselect
elif [ "$PICK_ALL" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
  : # keep what was detected
elif [ -t 0 ] && [ -r /dev/tty ]; then
  tui_select
else
  warn "No interactive terminal: the detected agents are used."
fi

CHOSEN=0
for i in "${!TARGET_KEYS[@]}"; do
  if [ "${STATES[$i]}" -eq 1 ]; then CHOSEN=1; fi
done
if [ "$CHOSEN" -eq 0 ]; then err "No agent selected."; exit 1; fi

# --- installation ------------------------------------------------------------
say "${C_BOLD}Installing${C_OFF}"

chmod +x "$REPO_DIR/bin/agent-init" "$REPO_DIR/bin/arp" "$REPO_DIR/bin/arp-hooks" \
         "$REPO_DIR/hooks/"*.sh "$REPO_DIR/statusline/"*.sh "$REPO_DIR/install.sh"
mkdir -p "$BIN_DIR"
for c in agent-init arp arp-hooks; do
  ln -sfn "$REPO_DIR/bin/$c" "$BIN_DIR/$c"
  ok "$c → $BIN_DIR/$c"
done

# Claude Code gets its skills from the plugin now. The links this repo used to
# make in ~/.claude/skills (commit, relay, resume) would load every skill twice.
remove_repo_links "$CLAUDE_SKILLS" "Claude Code"

# Codex has no plugin system: it still gets links, from the skills/ folder.
if [ "${STATES[1]}" -eq 1 ]; then
  mkdir -p "$CODEX_SKILLS"
  n=0
  for src in "$SKILLS_SRC"/*/; do
    [ -f "$src/SKILL.md" ] || continue
    name="$(basename "$src")"
    link="$CODEX_SKILLS/$name"
    # Do not overwrite a real skill that is not ours.
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "Codex CLI: '$name' already exists and is not a link — skipped"
      continue
    fi
    ln -sfn "${src%/}" "$link"; n=$((n + 1))
  done
  ok "Codex CLI: $n skills → $CODEX_SKILLS"
fi

# Persist the choice so agent-init does not ask again nor deduce it from the
# PATH: having codex installed does not mean wanting it in ARP.
mkdir -p "$HOME/.claude/arp"
: > "$HOME/.claude/arp/targets"
for i in "${!TARGET_KEYS[@]}"; do
  [ "${STATES[$i]}" -eq 1 ] && printf '%s\n' "${TARGET_KEYS[$i]}" >> "$HOME/.claude/arp/targets"
done

# --- statusline (Claude Code only) -------------------------------------------
if [ "${STATES[0]}" -eq 1 ]; then
  say ""
  say "${C_BOLD}Quota bridge${C_OFF} ${C_DIM}(statusline; the hooks come from the plugin)${C_OFF}"
  if ! command -v jq >/dev/null 2>&1; then
    warn "skipped: jq is missing. Install it and then: arp-hooks install"
  else
    DO_HOOKS=$ASSUME_YES
    if [ "$DO_HOOKS" -eq 0 ] && [ -t 0 ] && [ -r /dev/tty ]; then
      say "  ${C_DIM}Writes statusLine in ~/.claude/settings.json and removes old ARP hook"
      say "  entries (the plugin provides them). Adds without replacing, makes a backup.${C_OFF}"
      printf '  Install it? [Y/n] '
      read -r ans < /dev/tty || ans=""
      if [[ ! "$ans" =~ ^[nN]$ ]]; then DO_HOOKS=1; fi
    fi
    if [ "$DO_HOOKS" -eq 1 ]; then
      "$REPO_DIR/bin/arp-hooks" install || warn "failed — retry with: arp-hooks install"
    else
      say "  ${C_DIM}skipped — you can install it later with: arp-hooks install${C_OFF}"
    fi
  fi
fi

# --- graphify (optional) -----------------------------------------------------
say ""
say "${C_BOLD}Graphify${C_OFF} ${C_DIM}(optional — dependency analysis)${C_OFF}"
if command -v graphify >/dev/null 2>&1; then
  ok "already installed ($(graphify --version 2>/dev/null | head -1))"
elif [ "$HAS_UV" -eq 0 ]; then
  warn "skipped: uv is missing. Install it and then: uv tool install graphifyy"
else
  DO_IT=$ASSUME_YES
  if [ "$DO_IT" -eq 0 ] && [ -t 0 ] && [ -r /dev/tty ]; then
    printf '  Install Graphify with uv? [y/N] '
    read -r ans < /dev/tty || ans=""
    if [[ "$ans" =~ ^[yY]$ ]]; then DO_IT=1; fi
  fi
  if [ "$DO_IT" -eq 1 ]; then
    if uv tool install graphifyy; then
      ok "graphify installed"
      graphify install 2>/dev/null && ok "graphify skill registered" \
        || warn "register the skill by hand with: graphify install"
    else
      warn "Graphify installation failed — ARP works without it"
    fi
  else
    say "  ${C_DIM}skipped${C_OFF}"
  fi
fi

# --- closing -----------------------------------------------------------------
say ""
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not in your PATH. Add it to your ~/.zshrc:"
     say  "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

say "${C_OK}Installation complete.${C_OFF}"
say ""
say "  ${C_BOLD}agent-init${C_OFF}   in any project, to adopt it"
say "  ${C_BOLD}arp doctor${C_OFF}   what is installed"
say "  ${C_BOLD}arp update${C_OFF}   update from the remote"
say ""
say "${C_BOLD}Claude Code${C_OFF}: install the plugin from inside Claude Code (two commands):"
say "    /plugin marketplace add yezzzp/agent-relay-protocol"
say "    /plugin install agent-core@agent-core"
say "  Skills then run as /agent-core:work, /agent-core:commit …. Codex: \$commit \$relay \$resume"
say ""
say "${C_DIM}Linked by symlink from $REPO_DIR${C_OFF}"
say "${C_DIM}What you edit there takes effect immediately. Do not move the folder.${C_OFF}"
