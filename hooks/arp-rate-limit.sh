#!/usr/bin/env bash
#
# Hook StopFailure (matcher: rate_limit) — el hacha ya cayó.
#
# Cuando el turno muere por cuota agotada, marca la tarea activa del proyecto
# como HANDOFF para que el otro agente la encuentre con `resume`.
#
# Si no hay ninguna tarea activa, promueve el borrador que dejó
# arp-plan-capture.sh (.arp/current-plan.md) a docs/ai/tasks/<slug>.md. Sin eso,
# el trabajo hecho en modo plan nativo se perdería entero: el plan solo vive en
# la conversación.
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

[ "$touched" -eq 0 ] || exit 0

# Sin tarea activa: puede que el trabajo viniera del modo plan nativo, que no
# escribe nada en disco. arp-plan-capture.sh deja ahí el plan aprobado; esta es
# la única rama en la que ese borrador se convierte en task file.
DRAFT="$CWD/.arp/current-plan.md"
if [ ! -r "$DRAFT" ]; then
  printf '%s corte por cuota en %s (ninguna tarea IN_PROGRESS, sin borrador)\n' "$NOW" "$CWD" >> "$LOG"
  exit 0
fi

fm() {   # lee una clave del frontmatter del borrador, nunca del cuerpo
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
# No pisar una tarea existente (p.ej. una ya DONE con el mismo slug).
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
> **Task file generado automáticamente por ARP** al agotarse la cuota a mitad de
> turno. Contiene el plan que se aprobó, **no** las decisiones que se tomaron al
> ejecutarlo: el corte fue abrupto y nadie llegó a escribirlas.
>
> Reconstruye el estado real con `git log` y `git diff`, y ejecuta el comando de
> verificación antes de escribir código (skill `resume`).
EOF
  # La fecha de captura delata un borrador viejo: si el plan es de hace días,
  # puede que ya estuviera terminado y esto sea ruido. Que lo juzgue quien lea.
  CAPTURED="$(fm captured)"
  [ -n "$CAPTURED" ] && printf '>\n> Plan aprobado el %s. Corte: %s.\n' "$CAPTURED" "$NOW"

  printf '\n## Plan aprobado\n\n'
  # Cuerpo del borrador: todo lo que va después del frontmatter.
  awk 'NR==1 && $0=="---"      { infm=1; next }
       infm && $0=="---"       { infm=0; body=1; next }
       body && !seen && $0==""  { next }          # sin línea en blanco de más
       body                     { seen=1; print }' "$DRAFT"

  printf '\n## Estado del árbol al cortarse\n\n'
  printf 'Rama: `%s`\n\n' "${BRANCH:-desconocida}"

  printf 'Sin commitear:\n\n```\n'
  git -C "$CWD" status --porcelain 2>/dev/null | head -50 || true
  printf '```\n\n'

  printf 'Últimos commits:\n\n```\n'
  git -C "$CWD" log --oneline -10 2>/dev/null || true
  printf '```\n'
} > "$TARGET.arp-tmp" && mv "$TARGET.arp-tmp" "$TARGET"

# El borrador se consume: ya es un task file. Si no, un segundo corte sobre la
# misma tarea lo promovería otra vez y dejaría un duplicado.
rm -f "$DRAFT"

printf '%s corte por cuota — borrador promovido a %s (HANDOFF)\n' "$NOW" "$TARGET" >> "$LOG"
exit 0
