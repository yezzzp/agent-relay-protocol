#!/usr/bin/env bash
#
# Hook PostToolUse (matcher: ExitPlanMode) — captura el plan aprobado.
#
# El modo plan nativo de Claude Code vive solo en la conversación: el plan es el
# argumento de una llamada a herramienta y nunca toca el disco. Si la sesión se
# corta, se pierde entero. Este hook lo persiste en .arp/current-plan.md.
#
# Es un BORRADOR desechable, no un task file:
#   - todo va bien       -> lo sobrescribe el próximo plan; docs/ai/tasks/ sigue vacío
#   - corres /relay      -> la skill lo lee y escribe el task file real
#   - se corta la cuota  -> arp-rate-limit.sh lo promueve a docs/ai/tasks/ con HANDOFF
#
# Así se respeta el principio de ARP: el task file solo existe cuando hay relevo.
#
# PostToolUse solo dispara cuando la herramienta tuvo éxito, así que un plan
# rechazado por el usuario nunca llega aquí. Cuesta cero tokens: no entra en
# contexto. Nunca falla: siempre sale con 0.

set -uo pipefail

payload="$(cat)"
LOG="$HOME/.claude/arp/relay.log"
mkdir -p "$(dirname "$LOG")"

command -v jq >/dev/null 2>&1 || exit 0

CWD="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -n "$CWD" ] || CWD="$PWD"

# Solo en proyectos con ARP inicializado. En cualquier otro, crear .arp/ sería
# ensuciar el árbol con un directorio que su .gitignore no conoce.
[ -d "$CWD/docs/ai/tasks" ] || exit 0

# Un subagente que sale de modo plan trae su propio plan parcial. Capturarlo
# pisaría el del agente principal, que es el que representa la tarea.
[ "$(printf '%s' "$payload" | jq -r '.tool_response.isAgent // false' 2>/dev/null)" = "true" ] && exit 0

# El plan llega en tool_response.plan — verificado contra el payload real, no
# contra la documentación: ahí tool_input viene vacío. Se deja tool_input.plan
# como alternativa por si otra versión lo mueve de sitio.
PLAN="$(printf '%s' "$payload" | jq -r '.tool_response.plan // .tool_input.plan // empty' 2>/dev/null)"
if [ -z "$PLAN" ]; then
  # No damos por perdido el plan sin dejar rastro: el payload crudo queda a mano
  # para ver qué forma trae de verdad.
  printf '%s' "$payload" > "$HOME/.claude/arp/last-unparsed-payload.json" 2>/dev/null
  printf '%s plan aprobado sin contenido en %s (payload en ~/.claude/arp/last-unparsed-payload.json)\n' \
         "$(date -Is)" "$CWD" >> "$LOG"
  exit 0
fi

SESSION="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
BRANCH="$(git -C "$CWD" branch --show-current 2>/dev/null)"
NOW="$(date -Is)"

# Slug: la rama manda, salvo que sea una rama tronco. Si no, el primer título
# del plan. Se calcula aquí una vez para que arp-rate-limit.sh no tenga que
# adivinarlo en mitad de un corte.
slugify() {
  local out
  if out="$(printf '%s' "$1" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null)"; then
    printf '%s' "$out"
  else
    printf '%s' "$1"   # sin iconv: los acentos los quita el sed de norm()
  fi
}

norm() {
  slugify "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' \
    | cut -c1-50
}

SLUG=""
case "$BRANCH" in
  ''|main|master|develop|dev|trunk|HEAD) ;;
  *) SLUG="$(norm "$BRANCH")" ;;
esac

if [ -z "$SLUG" ]; then
  TITLE="$(printf '%s\n' "$PLAN" | grep -m1 -E '^#+[[:space:]]+' | sed -E 's/^#+[[:space:]]+//')"
  SLUG="$(norm "${TITLE:-plan}")"
fi
[ -n "$SLUG" ] || SLUG="plan"

DRAFT_DIR="$CWD/.arp"
DRAFT="$DRAFT_DIR/current-plan.md"
mkdir -p "$DRAFT_DIR" || exit 0

# Escritura atómica: el corte puede llegar justo aquí.
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

printf '%s plan capturado — %s (slug: %s)\n' "$NOW" "$DRAFT" "$SLUG" >> "$LOG"
exit 0
