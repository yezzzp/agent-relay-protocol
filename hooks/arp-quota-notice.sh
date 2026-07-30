#!/usr/bin/env bash
#
# Hook UserPromptSubmit — aviso de cuota.
#
# Lee ~/.claude/arp/quota.json (que escribe el statusline) y, si la ventana de
# 5 horas pasó el umbral, inyecta contexto por stdout para que el agente entre
# en modo relevo por su cuenta.
#
# Los hooks NO reciben rate_limits: por eso hace falta el archivo puente.
# Nunca falla: siempre sale con 0.

set -uo pipefail
cat > /dev/null   # drena stdin; no necesitamos el payload

QUOTA="$HOME/.claude/arp/quota.json"
THRESHOLD="${ARP_QUOTA_THRESHOLD:-80}"
MAX_AGE=900   # 15 min: más viejo que esto, el dato ya no es de fiar

[ -r "$QUOTA" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

read -r PCT TS RESET <<<"$(jq -r '[(.five_hour.used_percentage // -1 | floor),
                                   (.ts // 0),
                                   (.five_hour.resets_at // 0)] | @tsv' \
                           "$QUOTA" 2>/dev/null)" || exit 0

case "$PCT" in ''|*[!0-9-]*) exit 0 ;; esac
[ "$PCT" -lt "$THRESHOLD" ] && exit 0

NOW=$(date +%s)
# Un quota.json viejo suele ser de otra ventana de 5h ya reseteada.
[ $(( NOW - TS )) -gt "$MAX_AGE" ] && exit 0

MINS=0
[ "$RESET" -gt "$NOW" ] && MINS=$(( (RESET - NOW) / 60 ))

cat <<EOF
[ARP] Cuota del plan (ventana de 5h) al ${PCT}%. Reset en ~${MINS} min.

Esta sesión puede cortarse en seco a mitad de turno. A partir de ahora:
- Si la tarea actual no cabe en lo que queda, escribe el handoff YA
  (skill \`relay\`) antes de seguir editando código.
- Cierra cada paso con commit. Lo que no esté en disco se pierde.
- No empieces trabajo nuevo de largo aliento sin avisar al usuario.
EOF
exit 0
