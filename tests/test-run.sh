#!/usr/bin/env bash
# tests/test-run.sh — recording through sh -c, a locked database, release tiers, one database name.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'kill $LOCKER 2>/dev/null; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AGENT_CORE_DB="$WORK/db.sqlite" XDG_CACHE_HOME="$WORK/cache" AGENT_CORE_CONFIG_HOME="$WORK/config"
mkdir -p "$HOME" "$AGENT_CORE_CONFIG_HOME"
LOCKER=""
pass=0; fail=0
ok() { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  ✗ %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected «$3», got «$2»"; }
q() { python3 -I -c "import sqlite3,sys;print(sqlite3.connect(sys.argv[1]).execute(sys.argv[2]).fetchone()[0])" "$AGENT_CORE_DB" "$1"; }

P="$WORK/shop"; mkdir -p "$P/.arp"; git init -q "$P"
printf '[verify]\nquick = "true"\n' > "$P/.arp/config.toml"

# a fake playwright: writes a JSON report only when the json reporter is asked for
mkdir -p "$WORK/bin"
cat > "$WORK/bin/playwright" <<'PW'
#!/usr/bin/env bash
case "$*" in *json*) cat > "$PLAYWRIGHT_JSON_OUTPUT_FILE" <<'J'
{"suites":[{"file":"checkout.spec.ts","title":"checkout.spec.ts","specs":[{"title":"pays @flow checkout","file":"checkout.spec.ts","tests":[{"status":"expected","results":[{"duration":1200}]}]}]}],"stats":{"duration":1300}}
J
;; esac
exit 0
PW
chmod +x "$WORK/bin/playwright"
export PATH="$WORK/bin:$PATH"

printf '\ntest-run\n'
(cd "$P" && "$REPO/bin/arp" test-run --tier e2e --runner integrator -- sh -c "cd . && playwright test --grep @critical") >/dev/null 2>&1
eq "playwright inside sh -c is recorded" "$(q "SELECT COUNT(*) FROM results")" "1"

python3 -I - "$AGENT_CORE_DB" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1], isolation_level=None)
c.execute("BEGIN EXCLUSIVE"); time.sleep(30)
PY
LOCKER=$!; sleep 1
(cd "$P" && "$REPO/bin/arp" test-run --tier unit -- true) >/dev/null 2>"$WORK/err"; code=$?
eq "a locked database does not fail passing tests" "$code" "0"
grep -q "not recorded" "$WORK/err" && ok "it says the run was not recorded" || ko "it says the run was not recorded" "$(cat "$WORK/err")"
(cd "$P" && "$REPO/bin/arp" test-run --tier unit -- false) >/dev/null 2>&1; code=$?
eq "a failing test still fails while locked" "$code" "1"
kill $LOCKER 2>/dev/null; wait $LOCKER 2>/dev/null; LOCKER=""

printf '\nrelease tiers and database names\n'
grep -q '"verify.e2e_full", cfg\["verify"\]\["e2e_full"\], "e2e_full"' "$REPO/lib/agentcore/integrate.py" \
  && ok "release records the full e2e as e2e_full" || ko "release records the full e2e as e2e_full" "recorded as e2e"
n="$(grep -rn 'db_prefix"\] +' "$REPO/lib" | wc -l | tr -d ' ')"
eq "the test database name is built in one place" "$n" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
