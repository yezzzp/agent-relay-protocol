#!/usr/bin/env bash
#
# tests/integrate.sh — integrator, sessions, worktrees and config check.
# Throwaway repos in a temp dir, temp HOME, temp AGENT_CORE_DB.

set -u

REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
ARP="$REPO/bin/arp"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"; mkdir -p "$HOME"
export AGENT_CORE_DB="$WORK/tests.db"
export AGENT_CORE_CONFIG_HOME="$WORK/cfg"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; O=$'\033[0m'; else G=""; R=""; B=""; O=""; fi
pass=0; fail=0
ok() { printf '  %s✓%s %s\n' "$G" "$O" "$1"; pass=$((pass + 1)); }
ko() { printf '  %s✗%s %s\n      %s\n' "$R" "$O" "$1" "$2"; fail=$((fail + 1)); }
eq() { [ "$2" = "$3" ] && ok "$1" || ko "$1" "expected «$3», got «$2»"; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing «$3» in «$2»" ;; esac; }
group() { printf '\n%s%s%s\n' "$B" "$1" "$O"; }

# newrepo <name> <verify.full> -> main checkout path, on main, with develop and config
newrepo() {
  local d="$WORK/$1"
  git init -q "$d" && git -C "$d" symbolic-ref HEAD refs/heads/main
  mkdir -p "$d/.arp"
  cat > "$d/.arp/config.toml" <<CFG
[verify]
quick = "true"
full = "$2"
e2e = ""
e2e_full = ""
[env]
web_port = 39011
api_port = 39012
CFG
  printf '[checkout]\nsays = "A customer pays."\ncritical = true\n' > "$d/.arp/flows.toml"
  echo base > "$d/a.txt"
  git -C "$d" add -A && git -C "$d" commit -qm base
  git -C "$d" branch develop
  printf '%s' "$d"
}
# feature <repo> <branch> <file> <content> -> worktree with one commit
feature() {
  local wt="$1-wt/$2"
  git -C "$1" worktree add -q -b "$2" "$wt" develop
  echo "$4" > "$wt/$3"
  git -C "$wt" add -A && git -C "$wt" commit -qm "feat: $2"
}

group "arp integrate"

r="$(newrepo ok true)"
feature "$r" feat-a a.txt "from a" ; git -C "$r-wt/feat-a" checkout -q -- . 2>/dev/null
feature "$r" feat-b b.txt "from b"
before="$(git -C "$r" rev-parse develop)"
( cd "$r" && "$ARP" integrate feat-b --dry-run ) >/dev/null 2>&1
eq "dry run leaves develop alone" "$(git -C "$r" rev-parse develop)" "$before"
out="$(cd "$r" && "$ARP" integrate feat-b 2>&1)"; rc=$?
eq "clean branch lands: exit 0" "$rc" "0"
[ "$(git -C "$r" rev-parse develop)" != "$before" ] && ok "develop moved" || ko "develop moved" "unchanged"
[ -f "$r-wt/develop/b.txt" ] && ok "integration worktree has the file" || ko "integration worktree has the file" "missing"
ls "$r/.arp/integration/"*feat-b.md >/dev/null 2>&1 && ok "report written" || ko "report written" "none"
has "report says landed" "$(cat "$r"/.arp/integration/*feat-b.md)" "landed"

# dirty branch is refused
echo dirt > "$r-wt/feat-a/dirty.txt"
out="$(cd "$r" && "$ARP" integrate feat-a 2>&1)"; rc=$?
eq "dirty worktree refused" "$rc" "1"
has "dirty report names the branch" "$out" "feat-a"

group "failing verify"
r="$(newrepo bad false)"
feature "$r" feat-x x.txt "x"
before="$(git -C "$r" rev-parse develop)"
out="$(cd "$r" && "$ARP" integrate feat-x 2>&1)"; rc=$?
eq "failing verify.full: exit 1" "$rc" "1"
eq "develop unchanged" "$(git -C "$r" rev-parse develop)" "$before"
eq "integration worktree reset" "$(git -C "$r-wt/develop" rev-parse HEAD)" "$before"
has "tells who must fix" "$out" "must fix"

group "conflict"
r="$(newrepo conf true)"
feature "$r" feat-1 a.txt "one"
feature "$r" feat-2 a.txt "two"
( cd "$r" && "$ARP" integrate feat-1 ) >/dev/null 2>&1
before="$(git -C "$r" rev-parse develop)"
out="$(cd "$r" && "$ARP" integrate feat-2 2>&1)"; rc=$?
eq "conflict refused: exit 1" "$rc" "1"
eq "develop unchanged after conflict" "$(git -C "$r" rev-parse develop)" "$before"
has "names the conflicting file" "$out" "a.txt"
eq "no merge left in progress" "$(git -C "$r-wt/develop" status --porcelain | wc -l | tr -d ' ')" "0"

group "arp sessions"
r="$(newrepo ses true)"
feature "$r" feat-s s.txt "s"
( cd "$r-wt/feat-s" && "$ARP" sessions set ready ) >/dev/null
eq "state file written" "$(head -1 "$r-wt/feat-s/.arp/session-state")" "ready"
out="$(cd "$r" && "$ARP" sessions 2>&1)"
has "lists the branch with its state" "$out" "ready"
has "lists the main checkout" "$out" "main"
eq "--count format" "$(cd "$r" && "$ARP" sessions --count)" "0/3"
( cd "$r-wt/feat-s" && "$ARP" sessions set bogus ) >/dev/null 2>&1; rc=$?
eq "unknown state rejected" "$rc" "2"

group "arp worktrees prune"
( cd "$r" && "$ARP" integrate feat-s ) >/dev/null 2>&1
feature "$r" feat-open o.txt "open"
out="$(cd "$r" && "$ARP" worktrees prune 2>&1)"
has "dry run lists the merged one" "$out" "feat-s"
case "$out" in *feat-open*) ko "unmerged is kept" "listed feat-open" ;; *) ok "unmerged is kept" ;; esac
[ -d "$r-wt/feat-s" ] && ok "dry run removes nothing" || ko "dry run removes nothing" "gone"
( cd "$r" && "$ARP" worktrees prune --yes ) >/dev/null 2>&1
[ ! -d "$r-wt/feat-s" ] && ok "--yes removes the worktree" || ko "--yes removes the worktree" "still there"
git -C "$r" rev-parse --verify -q refs/heads/feat-s >/dev/null && ko "branch deleted" "still exists" || ok "branch deleted"
[ -d "$r-wt/develop" ] && [ -d "$r-wt/feat-open" ] && ok "integration and open worktrees kept" || ko "integration and open worktrees kept" "removed"

group "prune drops the test database with the integration branch's script"
rd="$(newrepo dropper true)"
git -C "$rd" worktree add -q "$rd-wt/develop" develop
mkdir -p "$rd-wt/develop/scripts"
printf '#!/bin/sh\necho "$1" >> %s/dropped.log\n' "$WORK" > "$rd-wt/develop/scripts/drop.sh"; chmod +x "$rd-wt/develop/scripts/drop.sh"
python3 - "$rd-wt/develop/.arp/config.toml" <<'PY2'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
p.write_text(p.read_text().replace("[env]\n", '[env]\ndb_prefix = "t_"\ndb_drop = "scripts/drop.sh {name}"\n', 1))
PY2
git -C "$rd-wt/develop" add -A && git -C "$rd-wt/develop" commit -qm "drop script on develop only"
feature "$rd" feat-d d.txt "d"
( cd "$rd-wt/feat-d" && "$ARP" integrate feat-d ) >/dev/null 2>&1
( cd "$rd" && "$ARP" worktrees prune --yes ) >/dev/null 2>&1
[ ! -d "$rd-wt/feat-d" ] && ok "pruned from the main checkout" || ko "pruned from the main checkout" "still there"
has "the drop script that only develop has ran" "$(cat "$WORK/dropped.log" 2>/dev/null)" "t_feat_d"

group "prune keeps a fresh branch after develop moves"
r="$(newrepo fresh true)"
git -C "$r" worktree add -q -b feat-new "$r-wt/feat-new" develop
printf 'SECRET=1\n' > "$r-wt/feat-new/.env"; printf '.env\n' > "$r.exclude"
git -C "$r" config core.excludesFile "$r.exclude"
feature "$r" feat-other x.txt "x"
( cd "$r" && "$ARP" integrate feat-other ) >/dev/null 2>&1
( cd "$r" && "$ARP" worktrees prune --yes ) >/dev/null 2>&1
[ -d "$r-wt/feat-new" ] && ok "a branch with no commits of its own is kept" || ko "a branch with no commits of its own is kept" "removed with its .env"
git -C "$r" rev-parse --verify -q refs/heads/feat-new >/dev/null && ok "its branch is kept" || ko "its branch is kept" "deleted"

group "prune skips a session marked working"
r="$(newrepo busy true)"
feature "$r" feat-busy b.txt "b"
( cd "$r" && "$ARP" integrate feat-busy ) >/dev/null 2>&1
( cd "$r-wt/feat-busy" && "$ARP" sessions set working ) >/dev/null
( cd "$r" && "$ARP" worktrees prune --yes ) >/dev/null 2>&1
[ -d "$r-wt/feat-busy" ] && ok "a working session is never pruned" || ko "a working session is never pruned" "removed"

group "never lose work (review round)"
r="$(newrepo keep true)"
feature "$r" feat-k k.txt "k"
mkdir -p "$r-wt/develop"; git -C "$r" worktree add -q "$r-wt/develop" develop 2>/dev/null
printf '# edited by hand\n' >> "$r-wt/develop/.arp/config.toml"
( cd "$r" && "$ARP" integrate feat-k --dry-run ) >/dev/null 2>&1
grep -q "edited by hand" "$r-wt/develop/.arp/config.toml" && ok "dry run keeps an edit to .arp/config.toml" || ko "dry run keeps an edit to .arp/config.toml" "reset"
( cd "$r" && "$ARP" integrate feat-k ) >/dev/null 2>&1
grep -q "edited by hand" "$r-wt/develop/.arp/config.toml" && ok "integrate refuses rather than reset it" || ko "integrate refuses rather than reset it" "reset"
git -C "$r-wt/develop" checkout -q -- .arp/config.toml

feature "$r" feat-cfg c.txt "c"
( cd "$r" && "$ARP" integrate feat-cfg ) >/dev/null 2>&1
printf '# mine\n' >> "$r-wt/feat-cfg/.arp/config.toml"
( cd "$r" && "$ARP" worktrees prune --yes ) >/dev/null 2>&1
[ -d "$r-wt/feat-cfg" ] && ok "prune keeps a worktree with an edited .arp/config.toml" || ko "prune keeps a worktree with an edited .arp/config.toml" "removed"

git -C "$r-wt/feat-cfg" checkout -q -- .arp/config.toml
out="$(cd "$r" && "$ARP" integrate feat-cfg 2>&1)"; rc=$?
has "integrating an already merged branch says so" "$out" "nothing to integrate"
out="$(cd "$r" && "$ARP" integrate main 2>&1)"; rc=$?
eq "the production branch is never integrated into develop" "$rc" "1"

r2="$(newrepo nochecks "")"
feature "$r2" feat-n n.txt "n"
out="$(cd "$r2" && "$ARP" integrate feat-n 2>&1)"; rc=$?
eq "no verify.full: integrate refuses" "$rc" "1"
has "and says what is missing" "$out" "verify.full"

group "after a landed integration"
ra="$(newrepo after true)"
printf '[integrate]\nafter = ["echo landed-hook > %s/after.log", "false"]\n' "$WORK" >> "$ra/.arp/config.toml"
git -C "$ra" commit -qam "after hooks" && git -C "$ra" branch -f develop
feature "$ra" feat-h h.txt "h"
out="$(cd "$ra" && "$ARP" integrate feat-h 2>&1)"; rc=$?
eq "a failing after step does not fail the landed integration" "$rc" "0"
[ -f "$ra-wt/develop/h.txt" ] && ok "and the merge stays" || ko "and the merge stays" "undone"
has "the after step ran in the integration worktree" "$(cat "$WORK/after.log" 2>/dev/null)" "landed-hook"
has "the report shows the failed after step" "$(cat "$ra"/.arp/integration/*feat-h.md)" "after: false"
rm -f "$WORK/after.log"
rb="$(newrepo after-bad false)"
printf '[integrate]\nafter = ["echo should-not > %s/after.log"]\n' "$WORK" >> "$rb/.arp/config.toml"
git -C "$rb" commit -qam "after hooks" && git -C "$rb" branch -f develop
feature "$rb" feat-i i.txt "i"
( cd "$rb" && "$ARP" integrate feat-i ) >/dev/null 2>&1
[ ! -f "$WORK/after.log" ] && ok "after steps never run when the integration fails" || ko "after steps never run when the integration fails" "ran"

group "queue: branches that wait go in together"
rq="$(newrepo queue "echo run >> $WORK/runs.log; sleep 2")"
feature "$rq" q-a qa.txt "a"; feature "$rq" q-b qb.txt "b"; feature "$rq" q-c qc.txt "c"
( cd "$rq-wt/q-a" && "$ARP" integrate q-a > "$WORK/q-a.out" 2>&1; echo $? > "$WORK/q-a.rc" ) &
sleep 0.8
( cd "$rq-wt/q-b" && "$ARP" integrate q-b > "$WORK/q-b.out" 2>&1; echo $? > "$WORK/q-b.rc" ) &
( cd "$rq-wt/q-c" && "$ARP" integrate q-c > "$WORK/q-c.out" 2>&1; echo $? > "$WORK/q-c.rc" ) &
wait
eq "the first branch lands" "$(cat "$WORK/q-a.rc")" "0"
eq "a waiting branch lands" "$(cat "$WORK/q-b.rc")" "0"
eq "the other waiting branch lands" "$(cat "$WORK/q-c.rc")" "0"
eq "the two that waited were verified in one run" "$(wc -l < "$WORK/runs.log" | tr -d ' ')" "2"
for f in qa qb qc; do git -C "$rq" cat-file -e "develop:$f.txt" 2>/dev/null || ko "develop has $f.txt" "missing"; done
has "a waiting session is told it was queued" "$(cat "$WORK/q-b.out")" "queued"
has "and gets its own result" "$(cat "$WORK/q-b.out")" "q-b: landed"
ls "$rq"/.arp/integration/*q-c.md >/dev/null 2>&1 && ok "each branch of a batch gets its report" || ko "each branch of a batch gets its report" "none for q-c"
has "the report says what it was verified with" "$(cat "$rq"/.arp/integration/*q-c.md)" "Verified together with: q-b"

group "queue: a failing batch is split"
rs="$(newrepo split "echo run >> $WORK/runs2.log; sleep 2; test ! -f bad.txt")"
feature "$rs" s-a sa.txt "a"; feature "$rs" s-b sb.txt "b"; feature "$rs" s-c bad.txt "boom"
( cd "$rs-wt/s-a" && "$ARP" integrate s-a > /dev/null 2>&1; echo $? > "$WORK/s-a.rc" ) &
sleep 0.8
( cd "$rs-wt/s-b" && "$ARP" integrate s-b > "$WORK/s-b.out" 2>&1; echo $? > "$WORK/s-b.rc" ) &
( cd "$rs-wt/s-c" && "$ARP" integrate s-c > "$WORK/s-c.out" 2>&1; echo $? > "$WORK/s-c.rc" ) &
wait
eq "the good branch of a failed batch still lands" "$(cat "$WORK/s-b.rc")" "0"
eq "the guilty branch is refused" "$(cat "$WORK/s-c.rc")" "1"
git -C "$rs" cat-file -e develop:sb.txt 2>/dev/null && ok "develop has the good branch" || ko "develop has the good branch" "missing"
git -C "$rs" cat-file -e develop:bad.txt 2>/dev/null && ko "develop never gets the guilty branch" "it did" || ok "develop never gets the guilty branch"
eq "runs: first, the batch, then each alone" "$(wc -l < "$WORK/runs2.log" | tr -d ' ')" "4"
has "the guilty one is told to fix it" "$(cat "$WORK/s-c.out")" "must fix"

group "test databases never collide"
r3="$(newrepo dbs true)"
printf '[env]\ndb_prefix = "t_"\nweb_port = 39011\napi_port = 39012\n' >> /dev/null
python3 -I - "$r3/.arp/config.toml" <<'PY'
import sys; p=sys.argv[1]; t=open(p).read().replace("[env]\n", '[env]\ndb_prefix = "t_"\ndb_rebuild = "echo REBUILD {name}"\n'); open(p,"w").write(t)
PY
git -C "$r3" commit -qam cfg; git -C "$r3" branch -f develop
( cd "$r3" && "$ARP" worktrees new web/orders.v2 ) >/dev/null 2>&1
out="$(cd "$r3" && "$ARP" worktrees new web/orders-v2 2>&1)"; rc=$?
eq "a second worktree with the same database name is refused" "$rc" "1"
mkdir -p "$r3-wt"; git -C "$r3" worktree add -q "$r3-wt/develop" develop 2>/dev/null
out="$(cd "$r3" && "$ARP" worktrees new Develop 2>&1)"; rc=$?
eq "a worktree cannot take the integration database" "$rc" "1"

group "only real dev servers are stopped"
r4="$(newrepo srv true)"
feature "$r4" feat-s2 s.txt "s"
( cd "$r4-wt/feat-s2" && exec -a "python3 notes/invite-list.md" sleep 30 ) &
SPID=$!
sleep 0.5
( cd "$r4" && "$ARP" integrate feat-s2 ) >/dev/null 2>&1
kill -0 $SPID 2>/dev/null && ok "a process named invite-list is not killed" || ko "a process named invite-list is not killed" "killed"
kill $SPID 2>/dev/null

group "missing integration worktree folder"
r5="$(newrepo gone true)"
feature "$r5" feat-g g.txt "g"
git -C "$r5" worktree add -q "$r5-wt/develop" develop; rm -rf "$r5-wt/develop"
out="$(cd "$r5" && "$ARP" integrate feat-g 2>&1)"; rc=$?
eq "a deleted integration folder is recreated and the merge lands" "$rc" "0"

group "arp config check"
r="$(newrepo cfg true)"
out="$(cd "$r" && "$ARP" config check 2>&1)"; rc=$?
eq "valid config passes" "$rc" "0"
has "prints ok" "$out" "ok"
: > "$r/.arp/flows.toml"
out="$(cd "$r" && "$ARP" config check 2>&1)"; rc=$?
eq "empty flows fails" "$rc" "1"
has "names flows.toml" "$out" "flows.toml"
printf '[checkout]\nsays = "x"\n' > "$r/.arp/flows.toml"
sed -i 's/^quick = .*/quick = ""/' "$r/.arp/config.toml"
out="$(cd "$r" && "$ARP" config check 2>&1)"; rc=$?
eq "missing verify.quick fails" "$rc" "1"
has "names verify.quick" "$out" "verify.quick"
sed -i 's/^quick = .*/quick = "true"/' "$r/.arp/config.toml"
python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',39011));s.listen();time.sleep(5)" &
sp=$!; sleep 0.5
out="$(cd "$r" && "$ARP" config check 2>&1)"; rc=$?
kill $sp 2>/dev/null
eq "taken port fails" "$rc" "1"
has "names the port" "$out" "39011"

printf '\n%s%d passed, %d failed%s\n' "$B" "$pass" "$fail" "$O"
[ "$fail" -eq 0 ]
