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
