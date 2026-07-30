#!/usr/bin/env bash
#
# Statusline de ARP.
#
# Hace dos cosas:
#   1. Dibuja la barra de estado.
#   2. Persiste rate_limits en ~/.claude/arp/quota.json
#
# El punto (2) es el que importa: el statusline es el ÚNICO lugar donde Claude Code
# expone la cuota del plan. Los hooks no la reciben. Este archivo es el puente que
# se la deja disponible al hook de UserPromptSubmit.

set -uo pipefail

input="$(cat)"
ARP_DIR="$HOME/.claude/arp"
QUOTA="$ARP_DIR/quota.json"

# --- 1. persistir la cuota ---------------------------------------------------
# Solo si rate_limits viene presente: aparece únicamente en planes Pro/Max y
# recién después de la primera respuesta de API de la sesión. Si falta, se
# conserva el último valor conocido en vez de sobrescribirlo con nulls.
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

# --- 2. dibujar --------------------------------------------------------------
DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; OFF=$'\033[0m'

# IFS de tabulador: los nombres de modelo llevan espacios ("Opus 5") y con el
# IFS por defecto se desplazarían todos los campos.
IFS=$'\t' read -r MODEL DIR CTX Q5 RESET <<<"$(printf '%s' "$input" | jq -r '
  [ (.model.display_name // "?"),
    (.workspace.current_dir // .cwd // "" | split("/") | last // "?"),
    (.context_window.used_percentage // 0 | floor),
    (.rate_limits.five_hour.used_percentage // -1 | floor),
    (.rate_limits.five_hour.resets_at // 0)
  ] | @tsv' 2>/dev/null)"

# Si jq falló (payload inesperado), los campos llegan vacíos: un statusline
# que escupe errores en cada render es peor que uno escueto.
[ -n "${MODEL:-}" ] || MODEL="?"
[ -n "${DIR:-}" ]   || DIR="?"
case "${CTX:-}" in ''|*[!0-9]*) CTX=0 ;; esac
case "${Q5:-}"  in ''|-1|*[!0-9]*) Q5=-1 ;; esac
case "${RESET:-}" in ''|*[!0-9]*) RESET=0 ;; esac

BRANCH="$(git branch --show-current 2>/dev/null || true)"
[ -n "$BRANCH" ] && BRANCH=" ${DIM}${BRANCH}${OFF}"

color_for() { # color_for <pct>
  if   [ "$1" -ge 90 ]; then printf '%s' "$RED"
  elif [ "$1" -ge 70 ]; then printf '%s' "$YEL"
  else printf '%s' "$GRN"; fi
}

OUT="${DIM}[${MODEL}]${OFF} ${DIR}${BRANCH}  ctx $(color_for "$CTX")${CTX}%${OFF}"

if [ "$Q5" -ge 0 ]; then
  MINS=0
  if [ "$RESET" -gt 0 ]; then MINS=$(( (RESET - $(date +%s)) / 60 )); fi
  [ "$MINS" -lt 0 ] && MINS=0
  OUT="$OUT  ${DIM}·${OFF} plan $(color_for "$Q5")${Q5}%${OFF} ${DIM}(reset ${MINS}m)${OFF}"
  if [ "$Q5" -ge "${ARP_QUOTA_THRESHOLD:-80}" ]; then
    OUT="$OUT ${RED}⚡relevo${OFF}"
  fi
fi

printf '%s\n' "$OUT"
