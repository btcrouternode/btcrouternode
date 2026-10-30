#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NODE-LOCK — review L1 (2026-10-10): one node operation at a time.
# Reproduces the .78 hardware race: a detached conf-restart worker is still
# running when Stop arrives — Stop must now be refused (node_busy) until the
# worker exits, and the lock must not outlive its owner.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v setsid >/dev/null 2>&1 || { echo "SKIP T-NODE-LOCK: no setsid"; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export NODE_OP_LOCK="$W/node-op.lock" BUSY_FILE="$W/node-busy" KNOTS_LIBEXEC="$K" KNOTS_LOGDIR="$W" NODE_OP_RESULT="$W/node-op.result"

# cgi-lib.sh sources the on-device rpc.sh; take only what the lock needs.
awk '/^cgi_headers\(\)/,/^}/; /^fail_json\(\)/,/^}/; /^cgi_setsid\(\)/,/^}/; /^require_node_idle\(\)/,/^}/; /^cgi_node_worker\(\)/,/^}/' \
	"$K/cgi-lib.sh" >"$W/cgi.sh"
echo 'json_escape() { printf "%s" "$1"; }' >>"$W/cgi.sh"

cgi() { # run a CGI-like snippet; prints its JSON (or ALLOW)
	sh -c ". '$K/node-impl-lib.sh'; . '$W/cgi.sh'; $1"
}

# 1. Acquire / refuse / release
sleep 30 & HOLDER=$!   # stands in for a live worker that owns the lock
out=$(cgi "require_node_idle conf 'Applying bitcoin.conf'; trap - EXIT; node_op_owner $HOLDER; echo ALLOW")
[ "$out" = ALLOW ] || fail "first acquire: $out"
out=$(cgi 'require_node_idle stop "Stopping"; echo ALLOW')
case "$out" in *'"error":"node_busy"'*'Applying bitcoin.conf'*) ;; *) fail "second op must be refused with node_busy: $out" ;; esac
kill "$HOLDER" 2>/dev/null || true
cgi 'node_op_release'
out=$(cgi 'require_node_idle stop "Stopping"; echo ALLOW')
[ "$out" = ALLOW ] || fail "acquire after release: $out"
[ ! -d "$NODE_OP_LOCK" ] || fail "CGI exit (EXIT trap) must release a lock not handed to a worker"
pass "acquire, refuse while held (node_busy + message), release on CGI exit"

# 2. A failed request after acquiring must not leave the node 'busy'
out=$(cgi 'require_node_idle start "Starting"; fail_json already_running "x"')
case "$out" in *already_running*) ;; *) fail "expected already_running: $out" ;; esac
[ ! -d "$NODE_OP_LOCK" ] && [ ! -f "$BUSY_FILE" ] || fail "refused request left the lock/busy behind"
pass "refusal after acquire releases the lock and busy message"

# 3. The .78 race: detached restart worker holds the lock until it finishes
cgi 'require_node_idle conf "Applying bitcoin.conf — restarting node"
cgi_node_worker conf-restart.log "sleep 3; echo restarted"; echo HANDED'
[ -d "$NODE_OP_LOCK" ] || fail "worker must own the lock after the CGI exits"
wpid=$(cat "$NODE_OP_LOCK/pid")
kill -0 "$wpid" 2>/dev/null || fail "lock owner must be the live worker (pid $wpid)"
out=$(cgi 'require_node_idle stop "Stopping Bitcoin node"; echo ALLOW')
case "$out" in *node_busy*) ;; *) fail "Stop during the restart worker must be refused: $out" ;; esac
[ "$(cgi 'read_node_busy' | cut -d'|' -f1)" = true ] || fail "read_node_busy must report busy while worker runs"
i=0; while [ -d "$NODE_OP_LOCK" ] && [ $i -lt 50 ]; do sleep 0.2; i=$((i+1)); done
[ ! -d "$NODE_OP_LOCK" ] || fail "worker must release the lock when it exits"
grep -q restarted "$W/conf-restart.log" || fail "worker did not run"
out=$(cgi 'require_node_idle stop "Stopping Bitcoin node"; echo ALLOW')
[ "$out" = ALLOW ] || fail "Stop after the worker finished must be accepted: $out"
pass "detached worker owns the lock; concurrent Stop refused; released on exit"

# 4. Stale lock (owner killed) is reclaimed and not reported as busy
mkdir -p "$NODE_OP_LOCK"; echo 999999 >"$NODE_OP_LOCK/pid"
printf 'conf\nstale msg\n%s\n' "$(date +%s)" >"$BUSY_FILE"
[ "$(cgi 'read_node_busy' | cut -d'|' -f1)" = false ] || fail "dead-owner lock must read as not busy"
[ ! -d "$NODE_OP_LOCK" ] || fail "read_node_busy must clear a dead-owner lock"
mkdir -p "$NODE_OP_LOCK"; echo 999999 >"$NODE_OP_LOCK/pid"
out=$(cgi 'require_node_idle stop "Stopping"; echo ALLOW')
[ "$out" = ALLOW ] || fail "dead-owner lock must be reclaimable: $out"
pass "stale lock (dead owner) reclaimed"

# 5. Wiring: every node-mutating action takes the lock
S="$K/settings-api.sh"; N="$K/node-impl-api.sh"
for a in conf_save node_stop node_start reboot shutdown factory_reset upgrade; do
	awk -v a="	$a)" 'index($0, a) == 1 { f = 1 } f && /^\t\t;;$/ { exit } f' "$S" | grep -q 'require_node_idle' \
		|| fail "settings-api $a must require_node_idle"
done
grep -q 'require_node_idle "\$ACTION"' "$N" || fail "node-impl-api must lock set/install/rollback/reindex"
grep -n 'clear_node_busy' "$S" "$N" && fail "APIs must release via node_op_release, not clear_node_busy"
grep -q '"node_busy":%s' "$S" || fail "settings status must expose node_busy"
pass "all Settings + Node software mutating actions take the lock; status exposes node_busy"

echo "ALL PASS: test-node-op-lock (T-NODE-LOCK)"
