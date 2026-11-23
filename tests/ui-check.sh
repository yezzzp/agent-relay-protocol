#!/usr/bin/env bash
# tests/ui-check.sh — ui-check + report.mjs against a static fixture. Skips if Playwright is missing.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
NODE_ROOT="${UI_CHECK_NODE_ROOT:-$PWD}"   # any folder whose node_modules has Playwright
command -v node >/dev/null && command -v python3 >/dev/null && command -v jq >/dev/null || { echo "skip: node, python3 and jq are required"; exit 0; }
[ -d "$NODE_ROOT/node_modules/playwright" ] || { echo "skip: Playwright not found in $NODE_ROOT"; exit 0; }

WORK="$(mktemp -d)"
trap 'kill "${SRV:-0}" 2>/dev/null; rm -rf "$WORK"' EXIT
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
(cd "$REPO/tests/fixtures/ui" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SRV=$!
for _ in $(seq 40); do curl -sf "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.25; done

mkdir -p "$WORK/project/.arp"
cat > "$WORK/project/.arp/config.toml" <<TOML
[ui]
base_url = "http://127.0.0.1:$PORT"
themes = ["light"]
viewports = ["1024x768"]
node_root = "$NODE_ROOT"
chat_selector = "#chat"
panel_selector = "#panel"
out = "out"
TOML

pass=0; fail=0
check() { if eval "$2"; then echo "  ok $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }

OUT="$(cd "$WORK/project" && node "$REPO/scripts/ui-check.mjs" --url / 2>&1)"; CODE=$?
J="$WORK/project/out/ui-check.json"
check "exits 1 on errors" '[ "$CODE" = 1 ]'
check "json written" '[ -f "$J" ]'
check "repeated title flagged" 'jq -e ".findings[]|select(.check==\"repeated-text\" and (.text|test(\"Stock by warehouse\")) and (.locations|length==2))" "$J" >/dev/null'
check "table cells not flagged" '! jq -e ".findings[]|select(.check==\"repeated-text\" and (.text|test(\"Total\")))" "$J" >/dev/null'
check "cut-off text flagged" 'jq -e ".findings[]|select(.check==\"cut-off-text\")" "$J" >/dev/null'
check "chat vs panel flagged" 'jq -e ".findings[]|select(.check==\"chat-repeats-panel\")" "$J" >/dev/null'
check "screenshot saved" '[ -s "$WORK/project/out/$(jq -r ".views[0].screenshot" "$J")" ]'

node "$REPO/scripts/report.mjs" "$J" --out "$WORK/r.html" >/dev/null
check "report has findings" 'grep -q "Repeated text" "$WORK/r.html" && grep -q "Cut-off text" "$WORK/r.html" && grep -q "data:image/jpeg;base64" "$WORK/r.html"'
echo '[{"question":"Should the subtitle go?"}]' > "$WORK/q.json"
node "$REPO/scripts/report.mjs" "$J" --before "$J" --after "$J" --questions "$WORK/q.json" --out "$WORK/r2.html" >/dev/null
check "report has before/after and questions" 'grep -q "Before and after" "$WORK/r2.html" && grep -q "Questions for you" "$WORK/r2.html"'
check "title appears once in body" '[ "$(grep -c "<h1>" "$WORK/r.html")" = 1 ]'

echo "ui-check: $pass passed, $fail failed"
[ "$fail" = 0 ]
