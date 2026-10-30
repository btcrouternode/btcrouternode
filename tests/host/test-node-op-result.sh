#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NODE-RESULT — review Phase 4 L2 / L3 (2026-10-11).
#  L2  detached node workers report what really happened (last_op):
#      running → ok | failed + message; explicit verdicts win; otherwise the
#      exit code decides (last log line as the reason); a worker killed
#      outright reads as failed once its lock owner is gone.
#      Stop/start/restart verify bitcoind; a failed switch reverts the impl.
#  L3  node-impl-api install / rollback / reindex run detached (no 120 s
#      proxy timeout) and answer "accepted"; the UI waits for last_op.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v setsid >/dev/null 2>&1 || { echo "SKIP T-NODE-RESULT: no setsid"; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export NODE_OP_LOCK="$W/node-op.lock" BUSY_FILE="$W/node-busy" KNOTS_LIBEXEC="$K" \
	KNOTS_LOGDIR="$W" NODE_OP_RESULT="$W/node-op.result"
awk '/^cgi_headers\(\)/,/^}/; /^fail_json\(\)/,/^}/; /^cgi_setsid\(\)/,/^}/; /^require_node_idle\(\)/,/^}/; /^cgi_node_worker\(\)/,/^}/' \
	"$K/cgi-lib.sh" >"$W/cgi.sh"
echo 'json_escape() { printf "%s" "$1"; }' >>"$W/cgi.sh"
cgi() { sh -c ". '$K/node-impl-lib.sh'; . '$W/cgi.sh'; $1"; }
res() { cat "$NODE_OP_RESULT" 2>/dev/null; }
wait_free() { i=0; while [ -d "$NODE_OP_LOCK" ] && [ $i -lt 60 ]; do sleep 0.2; i=$((i+1)); done; }
json_ok() { printf '%s' "$1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; }

# running while the worker is alive
cgi 'require_node_idle node_stop x; cgi_node_worker node-stop.log "sleep 2; node_op_result node_stop ok \"Bitcoin node stopped.\"" node_stop'
res | grep -q '"op":"node_stop","state":"running"' || fail "running state while worker alive ($(res))"
wait_free
res | grep -q '"state":"ok","message":"Bitcoin node stopped."' || fail "explicit ok verdict ($(res))"
pass "running → explicit ok verdict"

# explicit failure wins; exit code alone decides otherwise
cgi 'require_node_idle node_stop x; cgi_node_worker node-stop.log "node_op_result node_stop failed \"still running\"; exit 1" node_stop'
wait_free
res | grep -q '"state":"failed","message":"still running"' || fail "explicit failure ($(res))"
cgi 'require_node_idle set x; cgi_node_worker node-switch.log "echo \"node-impl: error: could not start Bitcoin Core; switched back to knots\" >&2; exit 1" set'
wait_free
res | grep -q '"op":"set","state":"failed","message":"error: could not start Bitcoin Core; switched back to knots"\|"op":"set","state":"failed","message":"could not start' \
	|| fail "exit code + last log line must become the failure reason ($(res))"
cgi 'require_node_idle conf x; cgi_node_worker conf-restart.log "true"'
wait_free
res | grep -q '"op":"conf_restart","state":"ok"' || fail "rc 0 without a verdict → ok, op from log name ($(res))"
pass "explicit failure wins; otherwise exit code decides (reason = last log line)"

# a worker killed outright: running record + dead owner → failed
cgi 'require_node_idle node_start x; cgi_node_worker node-start.log "sleep 30" node_start'
kill -9 "$(cat "$NODE_OP_LOCK/pid")"; sleep 0.3
out=$(cgi 'node_op_result_json')
json_ok "$out" || fail "last_op must be valid JSON: $out"
printf '%s' "$out" | grep -q '"state":"failed"' || fail "killed worker must read as failed: $out"
pass "killed worker reads as failed"

# messages stay valid JSON whatever they contain
cgi "node_op_result set failed 'bad \"quote\" back\\\\slash
newline	tab'"
json_ok "$(res)" || fail "result must stay valid JSON: $(res)"
pass "result JSON-safe"

# --- wiring: workers verify; no unconditional success
S="$K/settings-api.sh"; N="$K/node-impl-api.sh"
blk() { awk -v a="	$2)" 'index($0, a) == 1 { f = 1 } f && /^\t\t;;$/ { exit } f' "$1"; }
blk "$S" node_stop | grep -q 'node_op_result node_stop failed' || fail "stop must fail when bitcoind is still alive"
blk "$S" node_stop | grep -q '"node_running":false' && fail "stop must not claim node_running:false up front"
blk "$S" node_start | grep -q 'node_up' || fail "start must verify bitcoind came up"
blk "$S" node_start | grep -q 'echo running >/tmp/knots/knots.status$' && fail "start must not write running unconditionally"
blk "$S" conf_save | grep -q 'bitcoind_ctl_restart || true' && fail "conf restart must not swallow failure"
blk "$S" conf_save | grep -q 'node_op_result conf_restart failed' || fail "conf restart must report failure"
grep -q '"last_op":%s' "$S" || fail "settings status must expose last_op"
grep -q 'last_op' "$N" || fail "node status must expose last_op"
for a in install rollback reindex_chainstate set; do
	blk "$N" "$a" | grep -q 'cgi_node_worker' || fail "node-impl-api $a must run detached (L3)"
	blk "$N" "$a" | grep -q '"accepted":true' || [ "$a" = set ] || fail "node-impl-api $a must answer accepted"
done
blk "$N" install | grep -q 'out=$(/usr/libexec/knots/node-impl.sh install-from' && fail "install must not run inside the CGI"
awk '/switch to \$target failed/,/exit 1/' "$K/node-impl.sh" | grep -q 'write_impl "\$cur"' || fail "failed switch must revert the impl"
grep -q 'last_op' "$ROOT/files/www/knots/settings.js" || fail "settings.js must show last_op"
grep -q 'pollOp("install"' "$ROOT/files/www/knots/node.js" && grep -q 'pollOp("rollback"' "$ROOT/files/www/knots/node.js" \
	&& grep -q 'pollOp("set"' "$ROOT/files/www/knots/node.js" || fail "node.js must wait for last_op"
grep -q 'watchReindexStart' "$ROOT/files/www/knots/app.js" || fail "app.js must surface the reindex verdict"
pass "workers verify outcomes; install/rollback/reindex detached; UI shows last_op"

echo "ALL PASS: test-node-op-result (T-NODE-RESULT)"
