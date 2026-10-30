#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-UPGRADE-APPLY — review Phase 3 (U1/U2/U3, 2026-10-11).
#  U1  missing SHA in the pending record fails CLOSED; the image is moved to a
#      private path before verify, so a later upload cannot swap what is flashed.
#  U2  every failure removes pending + image, disarms upgrade.active, releases
#      locks, restarts a node it stopped (only if it was running); a stale
#      apply lock is reclaimed (no silent exit 0); the node-op lock is adopted
#      from the Settings CGI or acquired (resume path).
#  U2  setup-api upgrade_resume refuses a pending record older than 30 min and
#      status keeps upgrade.active while the apply worker is alive (B13);
#      settings upload trap keeps the specific failure (B17).
#  U3  uci-defaults 90/91 are thin wrappers over factory/apply-*.sh; a
#      configured unit gets topology only / keeps the owner's LAN RPC choice.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# --- sandbox: stub libexec + PATH tools; upgrade-apply.sh is the real script
setup() {
	rm -rf "$W/s"; mkdir -p "$W/s/lib" "$W/s/tmp" "$W/s/etc" "$W/s/bin"
	cp "$K/upgrade-apply.sh" "$W/s/lib/upgrade-apply.sh"
	cat >"$W/s/lib/upgrade-ui.sh" <<EOF
upgrade_ui_clear() { rm -f "$W/s/tmp/upgrade.active"; }
EOF
	: >"$W/s/lib/step-log.sh"; : >"$W/s/lib/progress-steps.sh"
	cat >"$W/s/lib/node-impl-lib.sh" <<EOF
NODE_OP_LOCK="$W/s/tmp/node-op.lock"
set_node_busy() { :; }; clear_node_busy() { :; }
node_op_acquire() {
	if mkdir "\$NODE_OP_LOCK" 2>/dev/null; then echo "\$\$" >"\$NODE_OP_LOCK/pid"; return 0; fi
	_p=\$(cat "\$NODE_OP_LOCK/pid" 2>/dev/null || true)
	[ -n "\$_p" ] && kill -0 "\$_p" 2>/dev/null && return 1
	rm -rf "\$NODE_OP_LOCK"; mkdir "\$NODE_OP_LOCK"; echo "\$\$" >"\$NODE_OP_LOCK/pid"
}
node_op_owner() { [ -d "\$NODE_OP_LOCK" ] && echo "\${1:-\$\$}" >"\$NODE_OP_LOCK/pid"; }
node_op_release() { rm -rf "\$NODE_OP_LOCK"; }
EOF
	cat >"$W/s/lib/bitcoind-ctl.sh" <<EOF
bitcoind_ctl_bitcoind_alive() { [ -f "$W/s/node-running" ]; }
EOF
	printf '#!/bin/sh\nrm -f "%s/s/node-running"; echo stopped >>"%s/s/calls"\n' "$W" "$W" >"$W/s/lib/pre-reboot-stop.sh"
	printf '#!/bin/sh\necho "start $*" >>"%s/s/calls"\n' "$W" >"$W/s/lib/knots-start.sh"
	# sysupgrade stub: records the file it was given (and a hash of it)
	printf '#!/bin/sh\nfor a; do f=$a; done\necho "sysupgrade $* $(sha256sum "$f" | cut -c1-64)" >>"%s/s/calls"\nexit ${SYSUPGRADE_RC:-0}\n' "$W" >"$W/s/bin/sysupgrade"
	printf '#!/bin/sh\nexit 0\n' >"$W/s/bin/logger"
	printf '#!/bin/sh\nexit 0\n' >"$W/s/bin/sleep"
	chmod +x "$W/s/lib/"*.sh "$W/s/bin/"*
	: >"$W/s/calls"
	head -c 4096 /dev/urandom >"$W/s/img"
	SHA=$(sha256sum "$W/s/img" | cut -c1-64)
	echo '{"armed":1}' >"$W/s/tmp/upgrade.active"
}
pending() { echo "pending 2026-10-11T00:00:00Z sz=4096 keep=1${1:+ sha256=$1}" >"$W/s/tmp/upgrade-pending"; }
apply() {
	KNOTS_SYSUPGRADE_HANDOFF_WAIT=10 KNOTS_LIBEXEC="$W/s/lib" KNOTS_TMP="$W/s/tmp" KNOTS_ETC="$W/s/etc" KNOTS_UPG_IMG="$W/s/img" \
		PATH="$W/s/bin:$PATH" sh "$W/s/lib/upgrade-apply.sh" >"$W/out" 2>&1
}
status() { cat "$W/s/tmp/upgrade-status.json" 2>/dev/null; }
cleaned() { # what
	[ ! -e "$W/s/tmp/upgrade-pending" ] || fail "$1: pending record left (resume could re-flash)"
	[ ! -e "$W/s/img" ] && [ ! -e "$W/s/tmp/upgrade-apply.work" ] || fail "$1: image left behind"
	[ ! -e "$W/s/tmp/upgrade.active" ] || fail "$1: upgrade.active left armed"
	[ ! -d "$W/s/tmp/upgrade-apply.lock" ] || fail "$1: apply lock left"
	[ ! -d "$W/s/tmp/node-op.lock" ] || fail "$1: node-op lock left"
}

# U1 — fail closed without a recorded SHA
setup; pending ""
apply && fail "no SHA: must fail"
status | grep -q '"phase":"failed".*no SHA256' || fail "no SHA: status must say why ($(status))"
grep -q sysupgrade "$W/s/calls" && fail "no SHA: sysupgrade must not run"
cleaned "no SHA"
pass "pending record without SHA256 fails closed, everything cleaned"

# U1 — mismatch fails, cleans up; node was not stopped yet → not started
setup; pending "$(printf '%064d' 0)"
apply && fail "mismatch: must fail"
status | grep -q 'mismatch' || fail "mismatch: status ($(status))"
grep -q 'start' "$W/s/calls" && fail "mismatch: must not start a node it never stopped"
cleaned "mismatch"
pass "SHA mismatch fails and cleans up"

# U1 — the flashed file is the private copy with the verified hash, even if a
# new upload lands at the shared path after verification
setup; pending "$SHA"
cat >"$W/s/lib/pre-reboot-stop.sh" <<EOF
#!/bin/sh
head -c 4096 /dev/urandom >"$W/s/img"   # second upload arrives mid-apply
EOF
chmod +x "$W/s/lib/pre-reboot-stop.sh"
apply || { cat "$W/out" >&2; fail "good image must apply"; }
grep -q "sysupgrade -v $W/s/tmp/upgrade-apply.work/image.itb $SHA" "$W/s/calls" \
	|| fail "must flash the private verified copy ($(cat "$W/s/calls"))"
pass "verified image moved private before the stop window; later upload cannot swap it"

# U2/B18 — sysupgrade failure: cleanup, running node restarted
setup; pending "$SHA"; : >"$W/s/node-running"
export SYSUPGRADE_RC=3
apply && fail "sysupgrade rc=3 must fail"
status | grep -q 'rc=3' || fail "rc in status ($(status))"
grep -q '^start start' "$W/s/calls" || fail "a node that was running must be restarted after a failed flash"
cleaned "sysupgrade failure"
setup; pending "$SHA"
apply || true
unset SYSUPGRADE_RC
grep -q '^start' "$W/s/calls" && fail "an owner-stopped node must stay stopped"
pass "failed sysupgrade cleans up; restarts only a node that was running"

# .88 UAT-UR-2 regression: sysupgrade returns non-zero while procd takes the
# image and then TERMs every process — the image must still be there.
setup; pending "$SHA"
cat >"$W/s/bin/sysupgrade" <<EOF
#!/bin/sh
echo "sysupgrade \$*" >>"$W/s/calls"
( /bin/sleep 1; kill -TERM \$PPID ) &
exit 246
EOF
chmod +x "$W/s/bin/sysupgrade"
rm -f "$W/s/bin/sleep"   # real sleep: the TERM must land inside the hand-off wait
apply || { cat "$W/out" >&2; fail "procd hand-off (rc=246 + TERM) must not count as failure"; }
[ -s "$W/s/tmp/upgrade-apply.work/image.itb" ] || fail "image deleted under procd during the sysupgrade hand-off"
[ -f "$W/s/tmp/upgrade-pending" ] && ! status | grep -q failed || fail "hand-off must not be reported as failed ($(status))"
pass "sysupgrade hand-off (non-zero rc, then TERM from procd) leaves the image for procd"

# U2/B19 — stale apply lock reclaimed; live one respected
setup; pending "$SHA"
mkdir "$W/s/tmp/upgrade-apply.lock"; echo 999999 >"$W/s/tmp/upgrade-apply.lock/pid"
apply || { cat "$W/out" >&2; fail "stale lock must be reclaimed"; }
grep -q sysupgrade "$W/s/calls" || fail "stale lock: sysupgrade must run"
setup; pending "$SHA"
sh -c 'sleep 30' & live=$!
mkdir "$W/s/tmp/upgrade-apply.lock"; echo $live >"$W/s/tmp/upgrade-apply.lock/pid"
apply || fail "live lock: second worker exits 0"
kill $live 2>/dev/null || true
grep -q sysupgrade "$W/s/calls" && fail "live lock: must not flash twice"
pass "stale apply lock reclaimed; a live worker is not duplicated"

# L1 — node-op lock: adopted from the uploading CGI; busy elsewhere → fail+clean
setup; pending "$SHA"
sh -c 'sleep 30' & cgi=$!
mkdir "$W/s/tmp/node-op.lock"; echo $cgi >"$W/s/tmp/node-op.lock/pid"
KNOTS_NODE_OP_FROM=$cgi apply || { kill $cgi; cat "$W/out" >&2; fail "must adopt the CGI's node-op lock"; }
grep -q sysupgrade "$W/s/calls" || { kill $cgi; fail "adopted lock: sysupgrade must run"; }
setup; pending "$SHA"
mkdir "$W/s/tmp/node-op.lock"; echo $cgi >"$W/s/tmp/node-op.lock/pid"
apply && { kill $cgi; fail "node-op busy: must refuse"; }
kill $cgi 2>/dev/null || true
grep -q sysupgrade "$W/s/calls" && fail "node-op busy: must not flash"
status | grep -q 'Another node operation' || fail "node-op busy status ($(status))"
pass "node-op lock adopted from Settings upload, acquired on resume, busy → refused"

# --- wiring (CGI paths run only on the router; checked structurally)
S="$K/setup-api.sh"
blk=$(awk '/^\tupgrade_resume\)/{f=1} f{print} f&&/^\t\t;;$/{exit}' "$S")
printf '%s\n' "$blk" | grep -q 'pending_expired' || fail "upgrade_resume must refuse a stale pending record"
printf '%s\n' "$blk" | grep -q -- '-le 1800' || fail "upgrade_resume pending age limit must be 30 min"
printf '%s\n' "$blk" | grep -q 'upgrade-apply.lock/pid' || fail "upgrade_resume must detect a live worker"
grep -q 'upgrade-apply.lock/pid' "$S" && awk '/B13/{f=1} f&&/kill -0 "\$_apply_pid"/{ok=1} END{exit !ok}' "$S" \
	|| fail "setup status must keep upgrade.active while the apply worker is alive (B13)"
grep -q 'KNOTS_NODE_OP_FROM=\$\$ setsid' "$K/settings-api.sh" || fail "settings upload must hand the node-op lock to the worker"
grep -F 'Upload interrupted' "$K/settings-api.sh" | grep -q 'phase.*failed.*||' \
	|| fail "settings upload trap must keep a specific failure (B17)"
pass "resume age gate, live-worker detection, B13 status, B17 trap, lock hand-off"

# --- U3 single source
for n in 90-knots-network:apply-network.sh:--topology-only 91-knots-firewall:apply-firewall.sh:--keep-owner; do
	f=${n%%:*}; r=${n#*:}; tgt=${r%%:*}; flag=${r#*:}
	u="$ROOT/files/etc/uci-defaults/$f"
	grep -q "exec /usr/libexec/knots/factory/$tgt $flag" "$u" || fail "$f must exec $tgt $flag on a configured unit"
	grep -q 'setup-complete' "$u" || fail "$f must key on setup-complete"
	[ "$(grep -c '^uci\|uci -q batch' "$u")" = 0 ] || fail "$f must not carry its own uci copy (single source, N5)"
done
F="$K/factory/apply-firewall.sh"
grep -q "firewall.dmz.output='REJECT'" "$F" || fail "apply-firewall must keep dmz.output REJECT"
grep -q 'device_dmz_rpc' "$F" || fail "apply-firewall must carry device_dmz_rpc"
pass "uci-defaults 90/91 single-source wrappers; configured units keep owner settings"

# U3 — run apply-firewall --keep-owner against a fake uci: owner's choice kept
mkdir -p "$W/u"
cat >"$W/u/uci" <<EOF
#!/bin/sh
[ "\$1" = -q ] && shift
case "\$1" in
get) grep -q "^\$2=" "$W/u/db" 2>/dev/null && sed -n "s/^\$2=//p" "$W/u/db" || exit 1 ;;
set) echo "\$2" | sed "s/'//g" >>"$W/u/db" ;;
batch) sed -n "s/^set //p" | sed "s/'//g" >>"$W/u/db" ;;
*) exit 0 ;;
esac
EOF
chmod +x "$W/u/uci"
# topology-only (keep-settings upgrade) never touches LAN / DHCP / host / TZ
: >"$W/u/db"
PATH="$W/u:$PATH" sh "$K/factory/apply-network.sh" --topology-only >/dev/null 2>&1 || fail "apply-network --topology-only"
grep -q '^network.br_dmz=device' "$W/u/db" || fail "topology-only must (re)apply the DMZ bridge"
grep -qE '^(network\.lan\.|dhcp\.|system\.)' "$W/u/db" && fail "topology-only touched owner settings: $(cat "$W/u/db")"
pass "apply-network --topology-only applies DMZ plumbing only"
ext() { sed -n "s/^firewall.$1.enabled=//p" "$W/u/db" | tail -1; }
printf 'firewall.knots_ext_rpc_dnat.enabled=1\nfirewall.knots_ext_rpc.enabled=1\n' >"$W/u/db"
PATH="$W/u:$PATH" sh "$F" --keep-owner >/dev/null 2>&1 || fail "apply-firewall --keep-owner"
[ "$(ext knots_ext_rpc_dnat)" = 1 ] && [ "$(ext knots_ext_rpc)" = 1 ] || fail "--keep-owner must keep LAN RPC enabled"
printf 'firewall.knots_ext_rpc_dnat.enabled=1\nfirewall.knots_ext_rpc.enabled=1\n' >"$W/u/db"
PATH="$W/u:$PATH" sh "$F" >/dev/null 2>&1 || fail "apply-firewall (reset)"
[ "$(ext knots_ext_rpc_dnat)" = 0 ] && [ "$(ext knots_ext_rpc)" = 0 ] || fail "factory baseline must switch LAN RPC off"
pass "keep-settings upgrade keeps the LAN RPC choice; factory baseline turns it off"

echo "ALL PASS: test-upgrade-apply (T-UPGRADE-APPLY)"
