#!/usr/bin/env bash
#
# ARP statusline.
#
# It does two things:
#   1. Draws the status bar.
#   2. Persists rate_limits to ~/.claude/arp/quota.json
#
# Point (2) is the one that matters: the statusline is the ONLY place where Claude
# Code exposes the plan quota. Hooks do not receive it. This file is the bridge
# that makes it available to the UserPromptSubmit hook.

set -uo pipefail

input="$(cat)"
ARP_DIR="$HOME/.claude/arp"
QUOTA="$ARP_DIR/quota.json"

# --- 1. persist the quota ---------------------------------------------------
# Only if rate_limits is present: it appears only on Pro/Max plans and only after
# the session's first API response. If missing, the last known value is kept
# instead of overwriting it with nulls.
if printf '%s' "$input" | jq -e '.rate_limits.five_hour.used_percentage != null' >/dev/null 2>&1; then
  mkdir -p "$ARP_DIR"
  printf '%s' "$input" \
    | jq -c --argjson now "$(date +%s)" \
        '{five_hour: .rate_limits.five_hour,
          seven_day: .rate_limits.seven_day,
          session_id: .session_id,
          ts: $now}' > "$QUOTA.tmp" 2>/dev/null \
    && mv -f "$QUOTA.tmp" "$QUOTA" 2>/dev/null || rm -f "$QUOTA.tmp"
fi

# --- 2. draw --------------------------------------------------------------
DIM=$'\033[2m'; RED=$'\033[31m'; OFF=$'\033[0m'

# Tab IFS: model names contain spaces ("Opus 5") and with the default IFS all
# the fields would shift.
IFS=$'\t' read -r MODEL MODEL_ID EFFORT DIR CTX Q5 RESET Q7 RESET7 <<<"$(printf '%s' "$input" | jq -r '
  [ (.model.display_name // "?"),
    (.model.id // "-"),
    (.effort.level // "-"),
    (.workspace.current_dir // .cwd // "" | split("/") | last // "?"),
    (.context_window.used_percentage // 0 | floor),
    (.rate_limits.five_hour.used_percentage // -1 | floor),
    (.rate_limits.five_hour.resets_at // 0),
    (.rate_limits.seven_day.used_percentage // -1 | floor),
    (.rate_limits.seven_day.resets_at // 0)
  ] | @tsv' 2>/dev/null)"

# If jq failed (unexpected payload), the fields arrive empty: a statusline that
# spits errors on every render is worse than a terse one.
[ -n "${MODEL:-}" ] || MODEL="?"
[ -n "${DIR:-}" ]   || DIR="?"
# Optional fields arrive as "-": a tab is whitespace for IFS and two tabs in a
# row would merge, shifting the following fields.
[ "${MODEL_ID:-}" = "-" ] && MODEL_ID=""
[ "${EFFORT:-}" = "-" ] && EFFORT=""
# If the payload has no effort, the one configured for the model in settings.json
# is used (modelSettings.<id>.effortLevel, or the global effortLevel).
if [ -z "${EFFORT:-}" ] && [ -n "${MODEL_ID:-}" ]; then
  EFFORT="$(jq -r --arg id "$MODEL_ID" \
    '.modelSettings[$id].effortLevel // .effortLevel // ""' \
    "$HOME/.claude/settings.json" 2>/dev/null)"
fi
[ -n "${EFFORT:-}" ] && MODEL="${MODEL} · ${EFFORT}"
case "${CTX:-}" in ''|*[!0-9]*) CTX=0 ;; esac
case "${Q5:-}"  in ''|-1|*[!0-9]*) Q5=-1 ;; esac
case "${RESET:-}" in ''|*[!0-9]*) RESET=0 ;; esac
case "${Q7:-}"  in ''|-1|*[!0-9]*) Q7=-1 ;; esac
case "${RESET7:-}" in ''|*[!0-9]*) RESET7=0 ;; esac

BRANCH="$(git branch --show-current 2>/dev/null || true)"
[ -n "$BRANCH" ] && BRANCH=" ${DIM}${BRANCH}${OFF}"

LEFT="${DIR}${BRANCH}"

# --- quota: a bar that alternates between the 5h window and the weekly one ---
# Changes every ARP_QUOTA_ROTATE seconds; for it to alternate without waiting for
# an event, settings.json carries statusLine.refreshInterval.
ORANGE=$'\033[38;2;217;119;87m'; GRAY=$'\033[38;5;240m'; BOLD=$'\033[1m'
BAR_W=10

left_for() { # left_for <resets_at> → "2h 10m" / "3d 4h"
  local secs=$(( $1 - $(date +%s) ))
  [ "$secs" -lt 0 ] && secs=0
  local d=$(( secs / 86400 )) h=$(( secs % 86400 / 3600 )) m=$(( secs % 3600 / 60 ))
  if   [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}

meter() { # meter <label> <pct> [resets_at]
  local pct=$2 fill i bar=""
  [ "$pct" -gt 100 ] && pct=100
  fill=$(( (pct * BAR_W + 50) / 100 ))
  [ "$pct" -gt 0 ] && [ "$fill" -eq 0 ] && fill=1
  for (( i = 0; i < BAR_W; i++ )); do
    if [ "$i" -lt "$fill" ]; then bar+="${ORANGE}━"; else bar+="${GRAY}─"; fi
  done
  local out="${DIM}$1${OFF} ${bar}${OFF} ${BOLD}$2%${OFF}"
  [ "${3:-0}" -gt 0 ] && out+=" ${DIM}· $(left_for "$3")${OFF}"
  printf '%s' "$out"
}

# --- sessions N/M ------------------------------------------------------------
# `arp sessions --count` prints "N/M" (or just "N"). It is called with a short
# timeout and cached for 30 s per project; any failure hides the segment.
SESS_TTL=30
sessions_segment() {
  local cwd key cache out now mtime arp_bin n m
  cwd="$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)"
  [ -n "$cwd" ] || cwd="$PWD"
  key="$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)"
  cache="$ARP_DIR/sessions-$key.cache"
  now=$(date +%s)
  mtime=$(stat -c %Y "$cache" 2>/dev/null || echo 0)
  if [ $(( now - mtime )) -ge "$SESS_TTL" ]; then
    arp_bin="$(command -v arp 2>/dev/null || true)"
    [ -n "$arp_bin" ] || arp_bin="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin/arp"
    out=""
    if [ -x "$arp_bin" ] && command -v timeout >/dev/null 2>&1; then
      out="$(cd "$cwd" 2>/dev/null && timeout 0.3 "$arp_bin" sessions --count 2>/dev/null | head -1)" || out=""
    fi
    mkdir -p "$ARP_DIR" 2>/dev/null
    printf '%s' "$out" > "$cache.tmp" 2>/dev/null && mv -f "$cache.tmp" "$cache" 2>/dev/null
  else
    out="$(cat "$cache" 2>/dev/null)"
  fi
  case "$out" in
    [0-9]*/[0-9]*) n="${out%%/*}"; m="${out##*/}" ;;
    [0-9]*)        n="$out"; m=3 ;;
    *)             return 0 ;;
  esac
  case "$n$m" in *[!0-9]*) return 0 ;; esac
  if [ "$n" -gt "$m" ]; then
    printf '%ssessions %s/%s%s' "$RED" "$n" "$m" "$OFF"
  else
    printf '%ssessions %s/%s%s' "$DIM" "$n" "$m" "$OFF"
  fi
}

SHOW=5h
if [ "$Q7" -ge 0 ]; then
  if [ "$Q5" -lt 0 ] || [ $(( $(date +%s) / ${ARP_QUOTA_ROTATE:-10} % 2 )) -eq 1 ]; then
    SHOW=week
  fi
fi

RIGHT="${DIM}${MODEL}${OFF}  $(meter ctx "$CTX")"
SESS="$(sessions_segment)"
[ -n "$SESS" ] && RIGHT+="  $SESS"
if [ "$SHOW" = week ]; then
  RIGHT+="  $(meter week "$Q7" "$RESET7")"
elif [ "$Q5" -ge 0 ]; then
  RIGHT+="  $(meter 5h "$Q5" "$RESET")"
fi
if [ "$Q5" -ge "${ARP_QUOTA_THRESHOLD:-80}" ]; then
  RIGHT+=" ${RED}⚡relay${OFF}"
fi

# --- align the bars to the right --------------------------------------------
# Claude Code does not pass the terminal width: /dev/tty is asked. If that is not
# possible, the bars stay glued to the left as before.
COLS="$( { stty size </dev/tty; } 2>/dev/null | cut -d' ' -f2)"
case "${COLS:-}" in ''|*[!0-9]*) COLS="${COLUMNS:-}" ;; esac
case "${COLS:-}" in ''|*[!0-9]*) COLS=0 ;; esac

visible_len() { # visible_len <text with ANSI> → columns it takes
  local plain
  plain="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')"
  LC_ALL=C.UTF-8 bash -c 'printf "%s" "${#1}"' _ "$plain"
}

# Margin: Claude Code indents the statusline and leaves room on the right.
GAP=2
if [ "$COLS" -gt 0 ]; then
  PAD=$(( COLS - $(visible_len "$LEFT") - $(visible_len "$RIGHT") - ${ARP_STATUS_MARGIN:-4} ))
  [ "$PAD" -gt "$GAP" ] && GAP=$PAD
fi
OUT="${LEFT}$(printf '%*s' "$GAP" '')${RIGHT}"

printf '%s\n' "$OUT"
