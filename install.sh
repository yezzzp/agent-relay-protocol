#!/usr/bin/env bash
#
# Agent Relay Protocol — instalador
#
# Enlaza (no copia) el comando agent-init y las skills de ARP a los directorios
# que lee cada agente. Al ser symlinks, un `git pull` en este repo actualiza
# todo automáticamente.
#
# Uso:
#   ./install.sh                       selector interactivo
#   ./install.sh --agents claude,codex sin interacción
#   ./install.sh --all --yes           todo lo detectado, sin preguntar
#   ./install.sh --uninstall           quita los enlaces

set -euo pipefail

# El repo se queda donde lo clonaste y es la instalación: todo se enlaza por
# symlink desde aquí. Así, lo que edites tiene efecto inmediato.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
SKILLS_SRC="$REPO_DIR/templates/skills"

# --- destinos: etiqueta | directorio de skills | comando que lo detecta ------
TARGET_KEYS=(claude codex)
TARGET_LABEL=("Claude Code" "Codex CLI")
TARGET_DIR=("$HOME/.claude/skills" "$HOME/.agents/skills")
TARGET_BIN=(claude codex)

STATES=() ; AVAIL=() ; CUR=0
ASSUME_YES=0 ; PICK_ALL=0 ; UNINSTALL=0 ; PRESELECT=""

C_DIM=$'\033[2m' ; C_OK=$'\033[32m' ; C_WARN=$'\033[33m'
C_ERR=$'\033[31m' ; C_BOLD=$'\033[1m' ; C_OFF=$'\033[0m'

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✓%s %s\n' "$C_OK"   "$C_OFF" "$*"; }
warn() { printf '%s!%s %s\n' "$C_WARN" "$C_OFF" "$*"; }
err()  { printf '%s✗%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }

usage() { sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# --- argumentos --------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --agents)    PRESELECT="${2:-}"; shift 2 ;;
    --agents=*)  PRESELECT="${1#*=}"; shift ;;
    --all)       PICK_ALL=1; shift ;;
    -y|--yes)    ASSUME_YES=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   usage ;;
    *)           err "Opción desconocida: $1"; usage ;;
  esac
done

# --- desinstalación ----------------------------------------------------------
if [ "$UNINSTALL" -eq 1 ]; then
  say "${C_BOLD}Quitando enlaces de ARP...${C_OFF}"
  if command -v jq >/dev/null 2>&1; then
    "$REPO_DIR/bin/arp-hooks" uninstall 2>/dev/null || true
  fi
  for c in agent-init arp arp-hooks; do
    if [ -L "$BIN_DIR/$c" ]; then rm -f "$BIN_DIR/$c"; ok "$c"; fi
  done
  for i in "${!TARGET_KEYS[@]}"; do
    for src in "$SKILLS_SRC"/*/; do
      link="${TARGET_DIR[$i]}/$(basename "$src")"
      # Solo borra si apunta a este repo: nunca toca skills ajenas.
      if [ -L "$link" ] && [[ "$(readlink "$link")" == "$REPO_DIR"* ]]; then
        rm -f "$link"; ok "${TARGET_LABEL[$i]}: $(basename "$src")"
      fi
    done
  done
  say "Listo."
  exit 0
fi

# --- dependencias ------------------------------------------------------------
say "${C_BOLD}Agent Relay Protocol${C_OFF} ${C_DIM}· $REPO_DIR${C_OFF}"
say ""
say "${C_BOLD}Dependencias${C_OFF}"

command -v git >/dev/null 2>&1 && ok "git" || warn "git no encontrado (agent-init lo necesita)"

HAS_UV=0
if command -v uv >/dev/null 2>&1; then HAS_UV=1; ok "uv"
else warn "uv no encontrado ${C_DIM}— necesario para Graphify${C_OFF}"; fi

for i in "${!TARGET_KEYS[@]}"; do
  if command -v "${TARGET_BIN[$i]}" >/dev/null 2>&1; then
    AVAIL[$i]=1; STATES[$i]=1; ok "${TARGET_LABEL[$i]}"
  else
    AVAIL[$i]=0; STATES[$i]=0; warn "${TARGET_LABEL[$i]} no encontrado"
  fi
done
say ""

# --- selección ---------------------------------------------------------------
apply_preselect() {
  local k found
  for i in "${!TARGET_KEYS[@]}"; do STATES[$i]=0; done
  IFS=',' read -ra _sel <<< "$PRESELECT"
  for k in "${_sel[@]}"; do
    found=0
    for i in "${!TARGET_KEYS[@]}"; do
      if [ "${TARGET_KEYS[$i]}" = "$k" ]; then STATES[$i]=1; found=1; fi
    done
    if [ "$found" -eq 0 ]; then err "Agente desconocido: $k"; exit 1; fi
  done
  return 0
}

draw_menu() {
  local i cursor mark line
  for i in "${!TARGET_KEYS[@]}"; do
    cursor="  " ; mark=" "
    [ "$i" -eq "$CUR" ] && cursor="❯ "
    [ "${STATES[$i]}" -eq 1 ] && mark="x"
    line=$(printf '%s[%s] %-13s %s' "$cursor" "$mark" "${TARGET_LABEL[$i]}" "${TARGET_DIR[$i]}")
    if [ "${AVAIL[$i]}" -eq 0 ]; then
      printf '%s%s  (no detectado)%s\n' "$C_DIM" "$line" "$C_OFF"
    else
      printf '%s\n' "$line"
    fi
  done
}

tui_select() {
  local key rest
  printf '%sInstalar las skills de ARP en:%s\n\n' "$C_BOLD" "$C_OFF"
  tput civis 2>/dev/null || true
  stty -echo < /dev/tty 2>/dev/null || true
  # Restaura la terminal pase lo que pase: sin esto, un Ctrl-C deja la
  # terminal sin eco y con el cursor oculto.
  trap 'tput cnorm 2>/dev/null; stty echo < /dev/tty 2>/dev/null; printf "\n"' EXIT INT TERM

  draw_menu
  printf '\n%s↑↓ mover · espacio marcar · enter confirmar · q cancelar%s' "$C_DIM" "$C_OFF"

  while true; do
    IFS= read -rsn1 key < /dev/tty
    case "$key" in
      $'\x1b')  # las flechas llegan como ESC [ A/B
        read -rsn2 -t 0.05 rest < /dev/tty || true
        case "$rest" in
          '[A') CUR=$(( (CUR - 1 + ${#TARGET_KEYS[@]}) % ${#TARGET_KEYS[@]} )) ;;
          '[B') CUR=$(( (CUR + 1) % ${#TARGET_KEYS[@]} )) ;;
        esac ;;
      k) CUR=$(( (CUR - 1 + ${#TARGET_KEYS[@]}) % ${#TARGET_KEYS[@]} )) ;;
      j) CUR=$(( (CUR + 1) % ${#TARGET_KEYS[@]} )) ;;
      ' ') STATES[$CUR]=$(( 1 - STATES[CUR] )) ;;
      q|Q) trap - EXIT INT TERM; tput cnorm 2>/dev/null; stty echo < /dev/tty 2>/dev/null
           printf '\n\nCancelado.\n'; exit 0 ;;
      '')  break ;;
    esac
    printf '\r'
    tput cuu $(( ${#TARGET_KEYS[@]} + 1 )) 2>/dev/null
    tput ed 2>/dev/null
    draw_menu
    printf '\n%s↑↓ mover · espacio marcar · enter confirmar · q cancelar%s' "$C_DIM" "$C_OFF"
  done

  trap - EXIT INT TERM
  tput cnorm 2>/dev/null || true
  stty echo < /dev/tty 2>/dev/null || true
  printf '\n\n'
}

if [ -n "$PRESELECT" ]; then
  apply_preselect
elif [ "$PICK_ALL" -eq 1 ] || [ "$ASSUME_YES" -eq 1 ]; then
  : # deja lo detectado
elif [ -t 0 ] && [ -r /dev/tty ]; then
  tui_select
else
  warn "Sin terminal interactiva: se usan los agentes detectados."
fi

CHOSEN=0
for i in "${!TARGET_KEYS[@]}"; do
  if [ "${STATES[$i]}" -eq 1 ]; then CHOSEN=1; fi
done
if [ "$CHOSEN" -eq 0 ]; then err "No se seleccionó ningún agente."; exit 1; fi

# --- instalación -------------------------------------------------------------
say "${C_BOLD}Instalando${C_OFF}"

chmod +x "$REPO_DIR/bin/agent-init" "$REPO_DIR/bin/arp" "$REPO_DIR/bin/arp-hooks" \
         "$REPO_DIR/hooks/"*.sh "$REPO_DIR/statusline/"*.sh "$REPO_DIR/install.sh"
mkdir -p "$BIN_DIR"
for c in agent-init arp arp-hooks; do
  ln -sfn "$REPO_DIR/bin/$c" "$BIN_DIR/$c"
  ok "$c → $BIN_DIR/$c"
done

for i in "${!TARGET_KEYS[@]}"; do
  [ "${STATES[$i]}" -eq 1 ] || continue
  mkdir -p "${TARGET_DIR[$i]}"
  n=0
  for src in "$SKILLS_SRC"/*/; do
    name="$(basename "$src")"
    link="${TARGET_DIR[$i]}/$name"
    # No pisar una skill real que no sea nuestra.
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      warn "${TARGET_LABEL[$i]}: '$name' ya existe y no es un enlace — se omite"
      continue
    fi
    ln -sfn "${src%/}" "$link"; n=$((n + 1))
  done
  ok "${TARGET_LABEL[$i]}: $n skills → ${TARGET_DIR[$i]}"
done

# --- puente de cuota (solo Claude Code) --------------------------------------
if [ "${STATES[0]}" -eq 1 ]; then
  say ""
  say "${C_BOLD}Puente de cuota${C_OFF} ${C_DIM}(statusline + hooks de relevo automático)${C_OFF}"
  if ! command -v jq >/dev/null 2>&1; then
    warn "omitido: falta jq. Instálalo y luego: arp-hooks install"
  else
    DO_HOOKS=$ASSUME_YES
    if [ "$DO_HOOKS" -eq 0 ] && [ -t 0 ] && [ -r /dev/tty ]; then
      say "  ${C_DIM}Escribe en ~/.claude/settings.json: statusLine, UserPromptSubmit"
      say "  y StopFailure. Añade sin reemplazar y hace copia de seguridad.${C_OFF}"
      printf '  ¿Instalarlo? [Y/n] '
      read -r ans < /dev/tty || ans=""
      if [[ ! "$ans" =~ ^[nN]$ ]]; then DO_HOOKS=1; fi
    fi
    if [ "$DO_HOOKS" -eq 1 ]; then
      "$REPO_DIR/bin/arp-hooks" install || warn "falló — reintenta con: arp-hooks install"
    else
      say "  ${C_DIM}omitido — puedes instalarlo luego con: arp-hooks install${C_OFF}"
    fi
  fi
fi

# --- graphify (opcional) -----------------------------------------------------
say ""
say "${C_BOLD}Graphify${C_OFF} ${C_DIM}(opcional — análisis de impacto en plan-review)${C_OFF}"
if command -v graphify >/dev/null 2>&1; then
  ok "ya instalado ($(graphify --version 2>/dev/null | head -1))"
elif [ "$HAS_UV" -eq 0 ]; then
  warn "omitido: falta uv. Instálalo y luego: uv tool install graphifyy"
else
  DO_IT=$ASSUME_YES
  if [ "$DO_IT" -eq 0 ] && [ -t 0 ] && [ -r /dev/tty ]; then
    printf '  ¿Instalar Graphify con uv? [y/N] '
    read -r ans < /dev/tty || ans=""
    if [[ "$ans" =~ ^[yYsS]$ ]]; then DO_IT=1; fi
  fi
  if [ "$DO_IT" -eq 1 ]; then
    if uv tool install graphifyy; then
      ok "graphify instalado"
      graphify install 2>/dev/null && ok "skill de graphify registrada" \
        || warn "registra la skill a mano con: graphify install"
    else
      warn "falló la instalación de Graphify — ARP funciona sin él"
    fi
  else
    say "  ${C_DIM}omitido${C_OFF}"
  fi
fi

# --- cierre ------------------------------------------------------------------
say ""
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR no está en tu PATH. Agrégalo a tu ~/.zshrc:"
     say  "    export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

say "${C_OK}Instalación completada.${C_OFF}"
say ""
say "  ${C_BOLD}agent-init${C_OFF}   en cualquier proyecto, para adoptarlo"
say "  ${C_BOLD}arp status${C_OFF}   qué hay instalado"
say "  ${C_BOLD}arp update${C_OFF}   actualizar desde el remoto"
say ""
say "  Claude: /relay  /resume  /plan-auto  /plan-review  /commit"
say "  Codex:  \$relay  \$resume  \$plan-auto  \$plan-review  \$commit"
say ""
say "${C_DIM}Enlazado por symlink desde $REPO_DIR${C_OFF}"
say "${C_DIM}Lo que edites ahí tiene efecto inmediato. No muevas la carpeta.${C_OFF}"
