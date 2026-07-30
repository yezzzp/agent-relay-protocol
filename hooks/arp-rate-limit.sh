#!/usr/bin/env bash
#
# Hook StopFailure (matcher: rate_limit) — el hacha ya cayó.
#
# Cuando el turno muere por cuota agotada, marca la tarea activa del proyecto
# como HANDOFF para que el otro agente la encuentre con `resume`.
#
# StopFailure es non-blocking: su salida y su código se ignoran. Solo sirve
# para efectos secundarios — que es justo lo que necesitamos.

set -uo pipefail

payload="$(cat)"
LOG="$HOME/.claude/arp/relay.log"
mkdir -p "$(dirname "$LOG")"

CWD="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="$PWD"

TASKS="$CWD/docs/ai/tasks"
[ -d "$TASKS" ] || { printf '%s corte por cuota en %s (sin docs/ai/tasks)\n' "$(date -Is)" "$CWD" >> "$LOG"; exit 0; }

NOW="$(date -Is)"
touched=0

for f in "$TASKS"/*.md; do
  [ -e "$f" ] || continue
  case "$(basename "$f")" in _TEMPLATE.md) continue ;; esac
  grep -qE '^status:[[:space:]]*IN_PROGRESS' "$f" || continue

  # Solo dentro del frontmatter (entre el primer par de ---), nunca en el cuerpo.
  awk -v now="$NOW" '
    NR==1 && $0=="---" { infm=1; print; next }
    infm && $0=="---"  { infm=0; print; next }
    infm && /^status:/  { print "status: HANDOFF"; next }
    infm && /^owner:/   { print "owner: none";     next }
    infm && /^updated:/ { print "updated: " now;   next }
    { print }
  ' "$f" > "$f.arp-tmp" && mv "$f.arp-tmp" "$f"

  printf '%s corte por cuota — %s marcado HANDOFF\n' "$NOW" "$f" >> "$LOG"
  touched=$((touched + 1))
done

if [ "$touched" -eq 0 ]; then
  printf '%s corte por cuota en %s (ninguna tarea IN_PROGRESS)\n' "$NOW" "$CWD" >> "$LOG"
fi
exit 0
