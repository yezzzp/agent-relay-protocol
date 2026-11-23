#!/usr/bin/env bash
#
# tests/test-health.sh — recorder, report and guard (arp test-*).
#
# Everything runs against temp repos with a temp HOME and a temp database.
# Usage: tests/test-health.sh        Exit: 0 all passed, 1 otherwise.

set -u

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ARP="$REPO/bin/arp"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export AGENT_CORE_DB="$WORK/db/agent-core.db"
export AGENT_CORE_CONFIG_HOME="$WORK/cfg"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; O=$'\033[0m'; else G=""; R=""; B=""; O=""; fi
pass=0; fail=0
ok() { printf '  %s✓%s %s\n' "$G" "$O" "$1"; pass=$((pass + 1)); }
ko() { printf '  %s✗%s %s\n      %s\n' "$R" "$O" "$1" "$2"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected «$3», got «$2»"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing «$3» in: $2" ;; esac; }
group() { printf '\n%s%s%s\n' "$B" "$1" "$O"; }
sql() { python3 -I -c 'import sqlite3,sys; print("\n".join("|".join(map(str,r)) for r in sqlite3.connect(sys.argv[1]).execute(sys.argv[2])))' "$AGENT_CORE_DB" "$1"; }

# newrepo <name> -> path of a git repo with one commit
newrepo() {
  local d="$WORK/$1"
  mkdir -p "$d"; git init -q "$d"
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email t@t; git -C "$d" config user.name t
  echo base > "$d/base.txt"; git -C "$d" add -A; git -C "$d" commit -qm base
  printf '%s' "$d"
}

# --- fixtures -----------------------------------------------------------------

FIX="$WORK/fix"; mkdir -p "$FIX"
cat > "$FIX/junit.xml" <<'X'
<?xml version="1.0" encoding="utf-8"?>
<testsuites><testsuite name="pytest" tests="4" time="1.50">
  <testcase classname="tests.test_prices" name="test_discount" time="0.10"/>
  <testcase classname="tests.test_prices.TestTax" name="test_rounding[2]" time="0.20"><failure message="boom">x</failure></testcase>
  <testcase classname="tests.test_stock" name="test_oversell" time="1.00"><skipped message="later"/></testcase>
  <testcase classname="tests.test_stock" name="test_wobbly" time="0.20"><failure message="x">x</failure></testcase>
  <testcase classname="tests.test_stock" name="test_wobbly" time="0.20"/>
</testsuite></testsuites>
X
cat > "$FIX/pw.json" <<'X'
{"stats":{"duration":4200},"suites":[{"title":"checkout.spec.ts","file":"checkout.spec.ts","specs":[],"suites":[
 {"title":"cart","file":"checkout.spec.ts","specs":[
  {"title":"pays and gets a receipt @flow checkout","file":"checkout.spec.ts","tests":[{"status":"expected","annotations":[],"results":[{"duration":2000,"status":"passed"}]}]},
  {"title":"flaky one","file":"checkout.spec.ts","tests":[{"status":"flaky","annotations":[{"type":"flow","description":"refund"}],"results":[{"duration":500,"status":"failed"},{"duration":600,"status":"passed"}]}]},
  {"title":"broken","file":"checkout.spec.ts","tests":[{"status":"unexpected","annotations":[],"results":[{"duration":900,"status":"failed"}]}]},
  {"title":"skipped","file":"checkout.spec.ts","tests":[{"status":"skipped","annotations":[],"results":[]}]}
 ]}]}]}
X

# --- recorder -----------------------------------------------------------------

group "test-record"
P="$(newrepo shop)"; cd "$P"
mkdir -p tests; touch tests/test_prices.py tests/test_stock.py
git add -A; git commit -qm tests
"$ARP" test-record --tier unit --runner integrator --junit "$FIX/junit.xml" >/dev/null
eq "junit: four distinct tests" "$(sql "select count(*) from tests")" "4"
eq "junit: file resolved from the classname" "$(sql "select file from tests where name='test_discount'")" "tests/test_prices.py"
eq "junit: class prefix kept in the name" "$(sql "select name from tests where name like 'TestTax%'")" "TestTax::test_rounding[2]"
eq "junit: fail" "$(sql "select outcome from results r join tests t on t.id=r.test_id where t.name like '%rounding%'")" "fail"
eq "junit: skip" "$(sql "select outcome from results r join tests t on t.id=r.test_id where t.name='test_oversell'")" "skip"
eq "junit: fail then pass is flaky" "$(sql "select outcome from results r join tests t on t.id=r.test_id where t.name='test_wobbly'")" "flaky"
eq "junit: run row has tier, runner and project" "$(sql "select tier||'/'||runner||'/'||(select name from projects) from runs")" "unit/integrator/shop"
"$ARP" test-record --tier e2e --playwright-json "$FIX/pw.json" >/dev/null
eq "playwright: pass" "$(sql "select outcome from results r join tests t on t.id=r.test_id where t.name like '%receipt%'")" "pass"
eq "playwright: flaky comes from the runner" "$(sql "select outcome from results r join tests t on t.id=r.test_id where t.name like '%flaky one'")" "flaky"
eq "playwright: unexpected is fail" "$(sql "select outcome from results r join tests t on t.id=r.test_id where t.name like '%broken'")" "fail"
eq "playwright: skipped" "$(sql "select outcome from results r join tests t on t.id=r.test_id where t.name like '%skipped'")" "skip"
eq "playwright: flow from the title tag" "$(sql "select flow from tests where name like '%receipt%'")" "checkout"
eq "playwright: flow from an annotation" "$(sql "select flow from tests where name like '%flaky one'")" "refund"
eq "playwright: tier e2e" "$(sql "select tier from tests where name like '%broken'")" "e2e"
"$ARP" test-record --tier unit --junit "$FIX/junit.xml" >/dev/null
eq "re-recording upserts tests" "$(sql "select count(*) from tests")" "8"
eq "two runs of the unit tests" "$(sql "select count(*) from runs where tier='unit'")" "2"

group "test-run"
out="$("$ARP" test-run --tier unit -- "exit 3" 2>&1)"; rc=$?
eq "passes the exit code through" "$rc" "3"
has "says when nothing was captured" "$out" "no per-test results"
eq "the run is recorded with no results" "$(sql "select count(*) from runs where command='exit 3'")" "1"
"$ARP" test-run --tier e2e --runner integrator -- sh -c 'echo $PYTEST_ADDOPTS > '"$WORK"'/addopts; echo $PLAYWRIGHT_JSON_OUTPUT_FILE > '"$WORK"'/pwenv' >/dev/null 2>&1
has "sets PYTEST_ADDOPTS with --junitxml" "$(cat "$WORK/addopts")" "--junitxml="
has "sets PLAYWRIGHT_JSON_OUTPUT_FILE" "$(cat "$WORK/pwenv")" "playwright.json"
# a command that writes the reports where the env says: proves capture end to end
"$ARP" test-run --tier unit -- sh -c "cp $FIX/junit.xml \$(echo \$PYTEST_ADDOPTS | sed 's/.*--junitxml=//')" >/dev/null 2>&1
eq "captures the junit file the command wrote" "$(sql "select count(*) from runs r join results x on x.run_id=r.id where r.command like 'sh -c%' ")" "4"
"$ARP" test-run --tier e2e -- sh -c "cp $FIX/pw.json \$PLAYWRIGHT_JSON_OUTPUT_FILE" >/dev/null 2>&1
eq "captures the playwright json the command wrote" "$(sql "select count(*) from runs r join results x on x.run_id=r.id where r.tier='e2e' and r.command like '%PLAYWRIGHT_JSON%'")" "4"
mkdir -p "$WORK/bin"; printf '#!/bin/sh\necho "$@" > %s/pwargs\n' "$WORK" > "$WORK/bin/playwright"; chmod +x "$WORK/bin/playwright"
PATH="$WORK/bin:$PATH" "$ARP" test-run --tier e2e -- "playwright test --grep x" >/dev/null 2>&1
has "adds the json reporter to a direct playwright command" "$(cat "$WORK/pwargs")" "--reporter=list,json"
if python3 -m pytest --version >/dev/null 2>&1; then
  cat > tests/test_real.py <<'PY'
def test_ok(): assert True
def test_bad(): assert False
PY
  "$ARP" test-run --tier unit -- python3 -m pytest -q tests/test_real.py >/dev/null 2>&1; rc=$?
  eq "real pytest: exit code 1 passes through" "$rc" "1"
  eq "real pytest: both tests captured" "$(sql "select group_concat(outcome) from (select outcome from results r join tests t on t.id=r.test_id where t.file='tests/test_real.py' order by t.name)")" "fail,pass"
fi
rm -f tests/test_real.py
mkdir -p .arp; printf '[tests]\nrecord = false\n' > .arp/config.toml
before="$(sql "select count(*) from runs")"
"$ARP" test-run --tier unit -- true >/dev/null 2>&1
eq "tests.record=false records nothing" "$(sql "select count(*) from runs")" "$before"
rm .arp/config.toml

# --- health -------------------------------------------------------------------

group "test-health"
# Make 'test_discount' look old and heavily covered, with a failure-free history.
python3 -I - "$AGENT_CORE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update tests set first_seen='2020-01-01T00:00:00+00:00'")
c.commit()
PY
# fake testmon database: test_discount covers src/prices.py
python3 -I - "$P/.testmondata" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("""
CREATE TABLE environment (id INTEGER PRIMARY KEY, environment_name TEXT);
CREATE TABLE test_execution (id INTEGER PRIMARY KEY, environment_id INTEGER, test_name TEXT, duration FLOAT, failed BIT, forced BIT);
CREATE TABLE file_fp (id INTEGER PRIMARY KEY, filename TEXT, method_checksums BLOB, mtime FLOAT, fsha TEXT);
CREATE TABLE test_execution_file_fp (test_execution_id INTEGER, fingerprint_id INTEGER);
INSERT INTO test_execution (id, test_name) VALUES (1, 'tests/test_prices.py::test_discount'), (2, 'tests/test_stock.py::test_wobbly');
INSERT INTO file_fp (id, filename) VALUES (1, 'src/prices.py'), (2, 'tests/test_prices.py'), (3, 'src/stock.py');
INSERT INTO test_execution_file_fp VALUES (1,1),(1,2),(2,3);
""")
c.commit()
PY
mkdir -p src
for i in 1 2 3; do echo "v$i" > src/prices.py; git add -A -- src; git commit -qm "prices $i"; done
echo s > src/stock.py; git add -A -- src; git commit -qm stock
out="$("$ARP" test-health --refresh-coverage 2>&1)"
has "coverage refresh reports the count" "$out" "coverage updated for 2"
eq "commits counted on covered source, not on tests" "$(sql "select commits from coverage_changes c join tests t on t.id=c.test_id where t.name='test_discount'")" "3"
printf '[tests]\nsuspect_runs = 3\n' > .arp/config.toml
out="$("$ARP" test-health --html "$WORK/report.html" 2>&1)"
has "summary names the project" "$out" "shop: 8 tests"
has "suspect detected (never failed, covered code changed)" "$out" "suspect: 3 commits  tests/test_prices.py::test_discount"
has "flaky detected" "$out" "flaky: tests/test_stock.py::test_wobbly"
has "failure value counted" "$out" "caught a failure: 2"
[ -s "$WORK/report.html" ] && ok "html report written" || ko "html report written" "empty"
html="$(cat "$WORK/report.html")"
for s in "cost" "flaky" "value" "suspects" "duplicates" "trend"; do has "html has the $s section" "$html" "shop $s"; done
has "html adapts to dark mode" "$html" "prefers-color-scheme: dark"
case "$html" in *"{{"*) ko "no placeholder left" "found {{" ;; *) ok "no placeholder left" ;; esac
rm .arp/config.toml
# without a testmon file the refresh is skipped, not an error
P2="$(newrepo other)"; cd "$P2"; mkdir -p tests; touch tests/test_x.py; git add -A; git commit -qm t
"$ARP" test-run --tier unit -- sh -c "cp $FIX/junit.xml \$(echo \$PYTEST_ADDOPTS | sed 's/.*--junitxml=//')" >/dev/null 2>&1
out="$("$ARP" test-health --refresh-coverage 2>&1)"; rc=$?
eq "missing .testmondata: exit 0" "$rc" "0"
has "missing .testmondata: says so" "$out" "coverage skipped"
echo "not sqlite" > .testmondata
out="$("$ARP" test-health --refresh-coverage 2>&1)"; rc=$?
eq "broken .testmondata: exit 0" "$rc" "0"
has "broken .testmondata: says so" "$out" "coverage skipped"
out="$("$ARP" test-health --all --html "$WORK/all.html" 2>&1)"
has "--all lists both projects" "$out" "other:"
has "--all compares in the page" "$(cat "$WORK/all.html")" "Projects compared"
# duplicates: same name in two files
sql "select 1" >/dev/null
python3 -I - "$AGENT_CORE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("insert into tests (project_id,file,name,tier,first_seen,last_seen) select project_id,'tests/other_prices.py',name,tier,first_seen,last_seen from tests where name='test_discount' and project_id=(select id from projects where name='shop')")
c.commit()
PY
cd "$P"
out="$("$ARP" test-health --html "$WORK/dup.html" 2>&1)"
has "duplicates: same name in two files" "$(cat "$WORK/dup.html")" "same name"
# prune: fold old results into totals
python3 -I - "$AGENT_CORE_DB" <<'PY'
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.execute("update runs set started_at='2020-02-02T00:00:00+00:00' where id=1")
c.commit()
PY
fails_before="$(sql "select count(*) from results where run_id=1 and outcome='fail'")"
"$ARP" test-health --prune >/dev/null 2>&1
eq "prune removes old raw results" "$(sql "select count(*) from results where run_id=1")" "0"
eq "prune keeps the failure in totals" "$(sql "select sum(fails) from test_totals")" "$fails_before"
eq "the run row itself survives" "$(sql "select count(*) from runs where id=1")" "1"

group "test-health --mutate"
out="$(PATH="$(dirname "$(command -v python3)"):/usr/bin:/bin" "$ARP" test-health --mutate 1 2>&1)"; rc=$?
if command -v mutmut >/dev/null 2>&1; then ok "mutmut installed: missing-tool path not exercised"
else
  eq "missing mutmut: exit 2" "$rc" "2"
  has "missing mutmut: says how to install" "$out" "pip install mutmut"
fi
printf '#!/bin/sh\ncase "$1" in --version) echo "mutmut, version 2.4.4";; *) echo "⠏ 5/5  🎉 0  ⏰ 0  🤔 0  🙁 5  🔇 0"; echo "$@" > %s/mutargs;; esac\n' "$WORK" > "$WORK/bin/mutmut"; chmod +x "$WORK/bin/mutmut"
tid="$(sql "select t.id from tests t join projects p on p.id=t.project_id where p.name='shop' and t.name='test_discount' and t.file='tests/test_prices.py'")"
out="$(PATH="$WORK/bin:$PATH" "$ARP" test-health --mutate "$tid" 2>&1)"
has "mutate limits mutmut to the covered file" "$(cat "$WORK/mutargs" 2>/dev/null)" "src/prices.py"
has "no mutant killed: delete candidate" "$out" "Delete candidate"
sed -i 's/🎉 0/🎉 4/; s/🙁 5/🙁 1/' "$WORK/bin/mutmut"
out="$(PATH="$WORK/bin:$PATH" "$ARP" test-health --mutate "tests/test_prices.py::test_discount" 2>&1)"
has "a killed mutant: test earns its place" "$out" "earns its place"

# --- guard --------------------------------------------------------------------

group "test-guard"
GR="$(newrepo guard)"; cd "$GR"
mkdir -p .arp e2e node_modules/pkg
cat > .arp/flows.toml <<'X'
[checkout]
says = "A customer pays."
critical = true
[refund]
says = "Staff refunds."
X
printf '[tests]\ne2e_per_flow = 2\n' > .arp/config.toml
cat > e2e/good.spec.ts <<'X'
import { test } from '@playwright/test';
test('pays and gets a receipt @flow checkout', async ({ page }) => {});
test('refund works', { tag: '@flow refund' }, async ({ page }) => {});
test.describe('checkout extras @flow checkout', () => {
  test('applies a coupon', async ({ page }) => {});
});
X
echo "test('no flow here', async () => {});" > node_modules/pkg/bad.spec.ts
out="$("$ARP" test-guard 2>&1)"; rc=$?
eq "clean project passes" "$rc" "0"
has "passing guard says ok" "$out" "test-guard: ok"
echo "test('forgot the tag', async () => {});" > e2e/notag.spec.ts
out="$("$ARP" test-guard 2>&1)"; rc=$?
eq "e2e test without @flow fails" "$rc" "1"
has "names the file, the test and the fix" "$out" "e2e/notag.spec.ts: e2e test \"forgot the tag\" names no flow. Fix:"
case "$out" in *node_modules*) ko "node_modules is skipped" "$out" ;; *) ok "node_modules is skipped" ;; esac
echo "test('invented @flow nowhere', async () => {});" > e2e/notag.spec.ts
out="$("$ARP" test-guard 2>&1)"; rc=$?
eq "unknown flow fails" "$rc" "1"
has "unknown flow names the missing flow" "$out" 'names flow "nowhere", which is not in .arp/flows.toml'
rm e2e/notag.spec.ts
echo "test('third @flow checkout', async () => {});" > e2e/third.spec.ts
out="$("$ARP" test-guard 2>&1)"; rc=$?
eq "flow over its cap fails" "$rc" "1"
has "cap message names flow, count and cap" "$out" 'flow "checkout" has 3 e2e tests, over the cap of 2'
rm e2e/third.spec.ts
printf 'export default defineConfig({ retries: 2, use: {} });\n' > playwright.config.ts
out="$("$ARP" test-guard 2>&1)"; rc=$?
eq "retries in the playwright config fail" "$rc" "1"
has "retries message names the fix" "$out" "Fix: remove the retries"
printf 'export default defineConfig({ retries: 0 });\n' > playwright.config.ts
"$ARP" test-guard >/dev/null 2>&1; eq "retries: 0 is fine" "$?" "0"
rm playwright.config.ts
echo "test.describe.configure({ retries: 1 });" > e2e/retry.spec.ts
"$ARP" test-guard >/dev/null 2>&1; eq "describe.configure retries fail" "$?" "1"
rm e2e/retry.spec.ts
mkdir -p tests; printf 'import pytest\n@pytest.mark.flaky(reruns=3)\ndef test_a(): pass\n' > tests/test_a.py
"$ARP" test-guard >/dev/null 2>&1; eq "pytest flaky marker fails" "$?" "1"
rm tests/test_a.py
printf '[tool.pytest.ini_options]\naddopts = "--reruns 2"\n' > pyproject.toml
"$ARP" test-guard >/dev/null 2>&1; eq "pytest --reruns fails" "$?" "1"
rm pyproject.toml

# baseline: existing offenders are grandfathered, new ones fail
echo "test('legacy', async () => {});" > e2e/legacy.spec.ts
"$ARP" test-guard >/dev/null 2>&1; eq "before baseline the offender fails" "$?" "1"
"$ARP" test-guard --baseline >/dev/null 2>&1
[ -f .arp/test-guard-baseline.json ] && ok "baseline file written" || ko "baseline file written" "missing"
"$ARP" test-guard >/dev/null 2>&1; eq "grandfathered offender passes" "$?" "0"
echo "test('brand new', async () => {});" >> e2e/legacy.spec.ts
out="$("$ARP" test-guard 2>&1)"; rc=$?
eq "a new offender still fails" "$rc" "1"
has "only the new one is reported" "$out" "brand new"
case "$out" in *'"legacy"'*) ko "legacy not re-reported" "$out" ;; *) ok "legacy not re-reported" ;; esac

printf '\n%s%d passed, %d failed%s\n' "$B" "$pass" "$fail" "$O"
[ "$fail" -eq 0 ]
