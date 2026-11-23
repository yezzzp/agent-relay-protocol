#!/usr/bin/env bash
# tests/tools.sh — missing tools on a new machine, and arp worktrees new.
set -uo pipefail
REPO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" AGENT_CORE_DB="$WORK/db.sqlite" XDG_CACHE_HOME="$WORK/cache" AGENT_CORE_CONFIG_HOME="$WORK/config"
mkdir -p "$HOME" "$AGENT_CORE_CONFIG_HOME"
pass=0; fail=0
ok() { printf '  ✓ %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  ✗ %s\n      %s\n' "$1" "$2"; fail=$((fail + 1)); }
has() { case "$2" in *"$3"*) ok "$1" ;; *) ko "$1" "missing «$3»" ;; esac; }
hasnt() { case "$2" in *"$3"*) ko "$1" "unexpected «$3»" ;; *) ok "$1" ;; esac; }
g() { git -c user.email=t@t -c user.name=t "$@"; }

# a bare PATH with only what agent-core itself needs
BIN="$WORK/bin"; mkdir -p "$BIN"
for t in git python3 bash sh env sed grep cat mkdir dirname readlink cp; do ln -s "$(command -v $t)" "$BIN/$t"; done

P="$WORK/shop"; mkdir -p "$P/.arp"; g init -q -b main "$P"
cat > "$P/.arp/config.toml" <<'T'
[verify]
quick = "uv run pytest -q --testmon"
e2e   = "cd web && pnpm exec playwright test --grep @critical"
[env]
db_prefix = "shop_test_"
copy = [".env", ".testmondata"]
T
touch "$P/uv.lock"
g -C "$P" add -A; g -C "$P" commit -qm base; g -C "$P" branch develop

printf '\ntools\n'
out="$(cd "$P" && PATH="$BIN" "$REPO/bin/arp" tools)"; code=$?
has "a missing runner is listed" "$out" "✗ uv (verify.quick)"
has "with its install command" "$out" "astral.sh/uv"
has "pnpm comes from the e2e command" "$out" "✗ pnpm (verify.e2e)"
has "missing project deps are listed" "$out" "uv sync"
hasnt "git is present, so not listed" "$out" "✗ git"
hasnt "a database prefix is not a tool" "$out" "shop_test_"
[ "$code" -eq 1 ] && ok "exit 1 when something is missing" || ko "exit 1" "got $code"
(cd "$P" && "$REPO/bin/arp" adopt >/dev/null)
hook="$(printf '{"cwd":"%s"}' "$P" | PATH="$BIN" "$REPO/bin/arp" session-start)"
has "the session is told what is missing" "$hook" "## Missing on this machine"
out="$(cd "$REPO" && "$REPO/bin/arp" tools)"
has "agent-core alone needs nothing more" "$out" "nothing missing"
mkdir -p "$P/web" "$P/mobile"; echo '{}' > "$P/web/package.json"; echo '{}' > "$P/mobile/package.json"
out="$(cd "$P" && PATH="$BIN" "$REPO/bin/arp" tools)"
has "node deps of a folder a command enters are listed" "$out" "node deps in web"
hasnt "a folder no command uses is not" "$out" "node deps in mobile"
rm -rf "$P/web" "$P/mobile"

printf '\nworktrees new\n'
mkdir -p "$P-wt"; g -C "$P" worktree add -q "$P-wt/develop" develop
printf 'SECRET=x\n' > "$P-wt/develop/.env"; printf 'map' > "$P-wt/develop/.testmondata"
out="$(cd "$P" && "$REPO/bin/arp" worktrees new web/orders)"
W="$P-wt/web-orders"
[ -d "$W" ] && ok "worktree created" || ko "worktree created" "$out"
[ "$(g -C "$W" branch --show-current)" = "web/orders" ] && ok "on its own branch" || ko "on its own branch" "wrong branch"
[ -f "$W/.testmondata" ] && ok "test map copied from the integration worktree" || ko "test map copied" "missing"
[ -f "$W/.env" ] && ok ".env copied" || ko ".env copied" "missing"
has "ports assigned" "$out" "ports: web 3011, api 8011"
has "test database named" "$out" "shop_test_web_orders"
out2="$(cd "$P" && "$REPO/bin/arp" worktrees new web/second)"
has "the next worktree takes the next ports" "$out2" "ports: web 3012, api 8012"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
