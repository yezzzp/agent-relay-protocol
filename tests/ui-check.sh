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
export WRITE_LOG="$WORK/writes.log"; : > "$WRITE_LOG"
python3 -I "$REPO/tests/fixtures/serve.py" "$PORT" "$REPO/tests/fixtures/ui" >/dev/null 2>&1 &
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

# never writes: Spanish labels, a title-only icon, a form button, a harmless-looking menu that posts
: > "$WRITE_LOG"
OUT="$(cd "$WORK/project" && node "$REPO/scripts/ui-check.mjs" --url /danger.html 2>&1)"
check "no write request reached the server" '[ ! -s "$WRITE_LOG" ]'
check "a blocked write is reported" 'jq -e ".findings[]|select(.check==\"blocked-write\" and (.text|test(\"menu-write\")))" "$J" >/dev/null'
check "whole words only: «Assigned to» is still opened" '! grep -q "Assigned to" <<<"$(jq -r ".findings[]|select(.check==\"blocked-write\")|.text" "$J")"'


# known failures: unbounded input, focus not restored, double submit (only with --probe)
: > "$WRITE_LOG"
OUT="$(cd "$WORK/project" && node "$REPO/scripts/ui-check.mjs" --url /behavior.html 2>&1)"
check "unbounded input flagged" 'jq -e ".findings[]|select(.check==\"unbounded-input\" and (.text|test(\"Buscar\")))" "$J" >/dev/null'
check "bounded input not flagged" '! jq -e ".findings[]|select(.check==\"unbounded-input\" and (.text|test(\"Nombre\")))" "$J" >/dev/null'
check "focus not restored flagged" 'jq -e ".findings[]|select(.check==\"focus-not-restored\" and (.text|test(\"Filtros\")))" "$J" >/dev/null'
check "focus restored after a close animation not flagged" '! jq -e ".findings[]|select(.check==\"focus-not-restored\" and (.text|test(\"Orden\")))" "$J" >/dev/null'
check "a trigger list that changes while open is not misread" '! jq -e ".findings[]|select(.check==\"focus-not-restored\" and (.text|test(\"Vista|Orden\")))" "$J" >/dev/null'
check "restored focus not flagged" '! jq -e ".findings[]|select(.check==\"focus-not-restored\" and (.text|test(\"Columnas\")))" "$J" >/dev/null'
check "no double-submit probe without --probe" '! jq -e ".findings[]|select(.check==\"double-submit\")" "$J" >/dev/null'
OUT="$(cd "$WORK/project" && node "$REPO/scripts/ui-check.mjs" --probe --url /behavior.html 2>&1)"; CODE=$?
check "double submit flagged" 'jq -e ".findings[]|select(.check==\"double-submit\" and .severity==\"error\" and (.text|test(\"Guardar pedido\")))" "$J" >/dev/null'
check "guarded button not flagged" '! jq -e ".findings[]|select(.check==\"double-submit\" and (.text|test(\"Emitir nota\")))" "$J" >/dev/null'
check "probe never writes" '[ ! -s "$WRITE_LOG" ]'
check "probe never clicks sign out" '! jq -e ".findings[]|select(.text|test(\"logout\"))" "$J" >/dev/null'
check "probe writes are not blocked-write noise" '! jq -e ".findings[]|select(.check==\"blocked-write\" and (.text|test(\"unguarded|guarded\")))" "$J" >/dev/null'

cat >> "$WORK/project/.arp/config.toml" <<TOML
[ui.login]
url = "/login.html"
email_env = "QA_U"
password_env = "QA_P"
email_selector = "label:Usuario"
password_selector = "label:Contraseña"
submit_selector = "button:Entrar"
TOML
OUT="$(cd "$WORK/project" && QA_U=a QA_P=bad node "$REPO/scripts/ui-check.mjs" --url /private.html 2>&1)"; CODE=$?
check "a failed login stops the run" '[ "$CODE" != 0 ] && grep -q "login failed" <<<"$OUT"'
OUT="$(cd "$WORK/project" && QA_U=a QA_P=good node "$REPO/scripts/ui-check.mjs" --url /private.html 2>&1)"; CODE=$?
check "a good login checks the private page" '[ "$CODE" = 0 ] && jq -e ".views[0].name==\"/private.html\"" "$J" >/dev/null'
OUT="$(cd "$WORK/project" && node "$REPO/scripts/ui-check.mjs" --no-login /danger.html 2>&1)"; CODE=$?
check "--no-login takes no value" '[ "$CODE" != 2 ]'

echo "ui-check: $pass passed, $fail failed"
[ "$fail" = 0 ]
