#!/usr/bin/env bash
#
# UserPromptSubmit hook — quota notice.
#
# Reads ~/.claude/arp/quota.json (written by the statusline) and, if the 5-hour
# window passed the threshold, injects context on stdout so the agent enters
# relay mode on its own.
#
# Hooks do NOT receive rate_limits: that is why the bridge file is needed.
# Never fails: always exits 0.

set -uo pipefail
cat > /dev/null   # drain stdin; the payload is not needed

QUOTA="$HOME/.claude/arp/quota.json"
THRESHOLD="${ARP_QUOTA_THRESHOLD:-80}"
MAX_AGE=900   # 15 min: older than this, the data cannot be trusted

[ -r "$QUOTA" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

read -r PCT TS RESET <<<"$(jq -r '[(.five_hour.used_percentage // -1 | floor),
                                   (.ts // 0),
                                   (.five_hour.resets_at // 0)] | @tsv' \
                           "$QUOTA" 2>/dev/null)" || exit 0

case "$PCT" in ''|*[!0-9-]*) exit 0 ;; esac
[ "$PCT" -lt "$THRESHOLD" ] && exit 0

NOW=$(date +%s)
# An old quota.json usually belongs to a 5h window that already reset.
[ $(( NOW - TS )) -gt "$MAX_AGE" ] && exit 0

MINS=0
[ "$RESET" -gt "$NOW" ] && MINS=$(( (RESET - NOW) / 60 ))

cat <<EOT
[ARP] Plan quota (5h window) at ${PCT}%. Resets in ~${MINS} min.

This session may be cut off mid-turn. From now on:
- If the current task does not fit in what is left, write the handoff NOW
  (skill \`relay\`) before editing more code.
- Close every step with a commit. Whatever is not on disk is lost.
- Do not start new long-running work without telling the user.
EOT
exit 0
