#!/usr/bin/env bash
#
# tests/run.sh — suite de los hooks de ARP.
#
# Corre los hooks con payloads sintéticos contra repos de mentira en un
# directorio temporal. No toca tu $HOME ni tus proyectos: reescribe HOME.
#
# Uso: tests/run.sh
# Salida: 0 si todo pasa, 1 si falla algo.

set -uo pipefail

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
CAPTURE="$REPO/hooks/arp-plan-capture.sh"
RATELIMIT="$REPO/hooks/arp-rate-limit.sh"
ARPHOOKS="$REPO/bin/arp-hooks"

command -v jq >/dev/null 2>&1 || { echo "✗ falta jq"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"   # los hooks escriben en $HOME/.claude/arp/relay.log
mkdir -p "$HOME/.claude"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; D=$'\033[2m'; O=$'\033[0m'
else G=""; R=""; B=""; D=""; O=""; fi

pass=0; fail=0
ok() { printf '  %s✓%s %s\n' "$G" "$O" "$1"; pass=$((pass + 1)); }
ko() { printf '  %s✗%s %s\n      %s\n' "$R" "$O" "$1" "$2"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "esperaba «$3», obtuve «$2»"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "no contiene «$3»" ;; esac; }
group() { printf '\n%s%s%s\n' "$B" "$1" "$O"; }

# --- utilidades ---------------------------------------------------------------

# newproj <nombre> [rama] -> imprime la ruta. Repo git con docs/ai/tasks/ y un commit.
newproj() {
  local d="$WORK/$1"
  mkdir -p "$d/docs/ai/tasks"
  git init -q "$d"
  git -C "$d" symbolic-ref HEAD refs/heads/main   # determinista: main, no master
  git -C "$d" config user.email arp@test
  git -C "$d" config user.name  arp
  echo base > "$d/base.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm "chore: base"
  [ -n "${2:-}" ] && git -C "$d" checkout -qb "$2"
  printf '%s' "$d"
}

# Forma real del payload, verificada contra uno capturado en vivo: el plan viaja
# en tool_response.plan y tool_input llega VACÍO. Si se prueba con tool_input se
# aprueba un hook que no funciona — ya pasó una vez.
capture() {
  jq -n --arg c "$1" --arg p "$2" \
    '{cwd:$c, session_id:"s1", hook_event_name:"PostToolUse", tool_name:"ExitPlanMode",
      tool_input:{}, tool_response:{plan:$p, isAgent:false, filePath:"/tmp/x.md"}}' | "$CAPTURE"
}
cut_()    { jq -n --arg c "$1" '{cwd:$c, hook_event_name:"StopFailure"}' | "$RATELIMIT"; }
front()   { sed -n "/^$2: /{s/^$2: //p;q;}" "$1"; }   # clave del frontmatter

# --- captura del plan ---------------------------------------------------------

group "arp-plan-capture.sh"

# El título manda sobre la rama: una rama de etapa aloja muchas tareas y todas
# acabarían con el mismo slug. Además se le quita el prefijo "Plan:".
p="$(newproj cap-titulo fase-1-modelo-multitenant)"
capture "$p" '# Plan: Logo de la marca en el login

paso uno'
eq "el título manda sobre la rama" "$(front "$p/.arp/current-plan.md" slug)" "logo-de-la-marca-en-el-login"
has "guarda el plan íntegro" "$(cat "$p/.arp/current-plan.md")" "paso uno"

p="$(newproj cap-planificacion)"
capture "$p" '# Planificación del cierre contable'
eq "no mutila un título que empieza por «Plan»" \
   "$(front "$p/.arp/current-plan.md" slug)" "planificacion-del-cierre-contable"

p="$(newproj cap-rama feat/Auth-Refactor)"
capture "$p" 'un plan sin ningún encabezado'
eq "sin título: cae a la rama, normalizada" "$(front "$p/.arp/current-plan.md" slug)" "feat-auth-refactor"

p="$(newproj cap-sin-arp)"; rm -rf "$p/docs"
capture "$p" '# Plan: no debería guardarse'
[ -e "$p/.arp" ] && ko "proyecto sin ARP: no crea .arp/" "creó .arp/" || ok "proyecto sin ARP: no crea .arp/"

p="$(newproj cap-acentos)"
capture "$p" '# Plan: Arreglar la exportación de PDF'
eq "transcribe los acentos" "$(front "$p/.arp/current-plan.md" slug)" "arreglar-la-exportacion-de-pdf"

p="$(newproj cap-sin-titulo)"   # sin título y en rama tronco: no queda de dónde sacarlo
capture "$p" 'texto suelto, sin ningún encabezado'
eq "sin título ni rama útil: slug de rescate" "$(front "$p/.arp/current-plan.md" slug)" "plan"

p="$(newproj cap-basura)"
echo 'esto no es json' | "$CAPTURE"; rc=$?
eq "JSON inválido: sale 0" "$rc" "0"

p="$(newproj cap-vacio)"
jq -n --arg c "$p" '{cwd:$c, tool_input:{}, tool_response:{}}' | "$CAPTURE"; rc=$?
eq "plan vacío: sale 0" "$rc" "0"
[ -e "$p/.arp/current-plan.md" ] && ko "plan vacío: no escribe borrador" "lo escribió" \
                                 || ok "plan vacío: no escribe borrador"

# Alternativa por si otra versión de Claude Code devuelve el plan en tool_input.
p="$(newproj cap-alterna)"
jq -n --arg c "$p" '{cwd:$c, tool_input:{plan:"# Plan: por la vía alterna"}}' | "$CAPTURE"
has "acepta el plan en tool_input si tool_response no lo trae" \
    "$(cat "$p/.arp/current-plan.md" 2>&1)" "por la vía alterna"

# Un subagente en modo plan no debe pisar el plan del agente principal.
p="$(newproj cap-subagente)"
capture "$p" '# Plan: el bueno, del agente principal'
jq -n --arg c "$p" '{cwd:$c, tool_response:{plan:"# Plan: de un subagente", isAgent:true}}' | "$CAPTURE"
has "un subagente no pisa el borrador" "$(cat "$p/.arp/current-plan.md")" "del agente principal"

# --- corte por cuota ----------------------------------------------------------

group "arp-rate-limit.sh"

# Una tarea IN_PROGRESS manda: se marca HANDOFF y el borrador ni se mira.
p="$(newproj rl-enprogreso)"
cat > "$p/docs/ai/tasks/activa.md" <<'EOF'
---
task: activa
owner: claude
status: IN_PROGRESS
branch: main
updated: viejo
---

# Real

---

trampa en el cuerpo: status: IN_PROGRESS y un --- suelto
EOF
capture "$p" '# Plan: borrador que no debe promoverse'
cut_ "$p"
eq "tarea activa -> HANDOFF"       "$(front "$p/docs/ai/tasks/activa.md" status)" "HANDOFF"
eq "tarea activa -> owner none"    "$(front "$p/docs/ai/tasks/activa.md" owner)"  "none"
eq "no promueve si ya había tarea" "$(ls "$p/docs/ai/tasks" | wc -l)" "1"
has "no toca el cuerpo del archivo" "$(cat "$p/docs/ai/tasks/activa.md")" "trampa en el cuerpo"

p="$(newproj rl-nada)"
cut_ "$p"
eq "sin tarea y sin borrador: no escribe nada" "$(ls -A "$p/docs/ai/tasks" | wc -l)" "0"

# El caso que da sentido a todo esto.
p="$(newproj rl-promueve fix/pdf-export)"
echo sucio > "$p/pendiente.txt"
capture "$p" '# Plan: Export de PDF

## Pasos
1. uno'
cut_ "$p"
t="$p/docs/ai/tasks/export-de-pdf.md"   # del título, no de la rama fix/pdf-export
[ -f "$t" ] && ok "promueve el borrador al slug correcto" || ko "promueve el borrador al slug correcto" "no existe $t"
eq  "promovido con status HANDOFF" "$(front "$t" status)" "HANDOFF"
eq  "conserva la rama"             "$(front "$t" branch)" "fix/pdf-export"
has "lleva el plan"                "$(cat "$t")" "## Pasos"
has "lleva el estado del árbol"    "$(cat "$t")" "pendiente.txt"
has "avisa de que es automático"   "$(cat "$t")" "generado automáticamente"
[ -e "$p/.arp/current-plan.md" ] && ko "consume el borrador" "sigue ahí" || ok "consume el borrador"

cut_ "$p"   # segundo corte sobre lo mismo
eq "dos cortes seguidos: un solo task file" "$(ls "$p/docs/ai/tasks" | wc -l)" "1"

# Colisión: nunca pisar un task file existente.
p="$(newproj rl-colision feat/choque)"
touch "$p/docs/ai/tasks/choque.md"   # mismo slug que va a generar el plan
capture "$p" '# Plan: choque'
cut_ "$p"
eq "colisión de nombre: no pisa, sufija" "$(ls "$p/docs/ai/tasks" | wc -l)" "2"

echo '' | "$RATELIMIT"; rc=$?
eq "payload vacío: sale 0" "$rc" "0"

# --- instalador de hooks ------------------------------------------------------

group "arp-hooks"

if ! command -v python3 >/dev/null 2>&1; then
  printf '  %somitido: falta python3%s\n' "$D" "$O"
else
  export HOME="$WORK/home2"; mkdir -p "$HOME/.claude"
  printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mio"}]}]}}\n' > "$HOME/.claude/settings.json"
  s="$HOME/.claude/settings.json"

  "$ARPHOOKS" install >/dev/null 2>&1
  eq "registra PostToolUse con matcher ExitPlanMode" \
     "$(jq -r '[.hooks.PostToolUse[] | select(.matcher=="ExitPlanMode")] | length' "$s")" "1"
  eq "registra los cuatro enganches" \
     "$(jq -r '[.statusLine, .hooks.UserPromptSubmit, .hooks.PostToolUse, .hooks.StopFailure] | map(select(. != null)) | length' "$s")" "4"

  "$ARPHOOKS" install >/dev/null 2>&1
  eq "idempotente: no duplica" \
     "$(jq -r '[.hooks.PostToolUse[].hooks[]] | length' "$s")" "1"

  "$ARPHOOKS" uninstall >/dev/null 2>&1
  eq "uninstall respeta los hooks ajenos" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$s")" "echo mio"
  eq "uninstall se lleva los suyos"       "$(jq -r '.hooks.PostToolUse // "ninguno"' "$s")" "ninguno"
fi

# --- resultado ----------------------------------------------------------------

printf '\n%s%d pasaron, %d fallaron%s\n' "$B" "$pass" "$fail" "$O"
[ "$fail" -eq 0 ]
