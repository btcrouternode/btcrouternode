#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# T-CLOCK: a router clock behind the chain is not a damaged chain (.107 router B).
#  - clock-floor.sh: floor = newest M.2 data; apply sets the clock forward only
#    when it is behind; stamp only with a clock that is not behind
#  - bitcoind-ctl: "block from the future" → clock_wrong, NEVER needs_reindex
#  - status API / start script / hotplug wiring
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
F="$ROOT/files"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- clock-floor.sh with a stub date (records -s, passes everything else on) ---
D="$W/data"; mkdir -p "$D/blocks" "$W/bin"
REAL_DATE=$(command -v date)
cat >"$W/bin/date" <<STUB
#!/bin/sh
for a in "\$@"; do [ "\$a" = "-s" ] && { echo "\$*" >>"$W/date-set.log"; exit 0; }; done
exec $REAL_DATE "\$@"
STUB
chmod +x "$W/bin/date"
CF="$F/usr/libexec/knots/clock-floor.sh"
run() { PATH="$W/bin:$PATH" KNOTS_DATADIR="$D" sh "$CF" "$@"; }

touch -d "2020-01-01 00:00:00 UTC" "$D/peers.dat" "$D/blocks/blk00000.dat" "$D/blocks"
[ "$(run floor)" = "$(date -d '2020-01-01 00:00:00 UTC' +%s)" ] || fail "floor must be the newest data time: $(run floor)"
: >"$W/date-set.log"; run apply >/dev/null
[ ! -s "$W/date-set.log" ] || fail "apply must not touch a clock that is ahead of the data: $(cat "$W/date-set.log")"
run stamp; [ -f "$D/.clock-stamp" ] || fail "stamp must record a good clock"
pass "clock ahead of the data: left alone, stamp recorded"

rm -f "$D/.clock-stamp"
FUT=$(( $(date +%s) + 86400 * 30 ))
touch -d "@$FUT" "$D/blocks/blk00001.dat"
[ "$(run floor)" = "$FUT" ] || fail "floor must follow the newest block file"
: >"$W/date-set.log"; out=$(run apply)
[ "$out" = "set-forward" ] && grep -q -- "-s $(date -u -d "@$FUT" '+%Y-%m-%d %H:%M:%S')" "$W/date-set.log" \
	|| fail "apply must set the clock forward to the newest data: out=$out log=$(cat "$W/date-set.log")"
run stamp; [ ! -f "$D/.clock-stamp" ] || fail "a clock behind the data must never stamp"
pass "clock behind the chain (firmware build date): set forward to the newest M.2 data; no stamp"

# --- bitcoind-ctl: future-block error is the clock, not a reindex -----------
L="$W/mnt"; mkdir -p "$L"
CTL="$W/ctl.sh"
sed -e "s|/mnt/bitcoin/debug.log|$L/debug.log|g" -e 's|^\. /usr/libexec/knots/rpc.sh|: # rpc.sh not needed here|' \
	"$F/usr/libexec/knots/bitcoind-ctl.sh" >"$CTL"
chk() { sh -c ". '$CTL'; $1" && echo yes || echo no; }
cat >"$L/debug.log" <<'LOG'
2026-07-24T07:22:19Z Bitcoin Core version v29.0.0 (release build)
2026-07-24T07:22:20Z init message: Loading block index…
2026-07-24T07:22:20Z init message: Verifying blocks…
2026-07-24T07:22:20Z : The block database contains a block which appears to be from the future. This may be due to your computer's date and time being set incorrectly. Only rebuild the block database if you are sure that your computer's date and time are correct.
Please restart with -reindex or -reindex-chainstate to recover.
2026-07-24T07:22:21Z Shutdown: done
LOG
[ "$(chk bitcoind_ctl_log_clock_wrong)" = yes ] || fail "future-block error must be detected as a wrong clock"
[ "$(chk bitcoind_ctl_log_needs_reindex)" = no ] || fail "future-block error must NEVER count as needs_reindex"
cat >>"$L/debug.log" <<'LOG'
2026-10-25T00:47:47Z Bitcoin Core version v29.0.0 (release build)
2026-10-25T00:47:48Z init message: Loading block index…
2026-10-25T00:48:11Z init message: Loading P2P addresses…
LOG
[ "$(chk bitcoind_ctl_log_clock_wrong)" = no ] || fail "after a good start the old clock error must not count"
cat >"$L/debug.log" <<'LOG'
2026-10-25T00:47:47Z Bitcoin Core version v29.0.0 (release build)
2026-10-25T00:47:48Z init message: Loading block index…
2026-10-25T00:47:49Z : Error initializing block database.
Please restart with -reindex or -reindex-chainstate to recover.
LOG
[ "$(chk bitcoind_ctl_log_clock_wrong)" = no ] && [ "$(chk bitcoind_ctl_log_needs_reindex)" = yes ] \
	|| fail "a real database error must still ask for a reindex"
pass "bitcoind 'block from the future' = waiting for the time, never a reindex; real damage still → reindex"

# --- wiring -----------------------------------------------------------------
KS="$F/usr/libexec/knots/knots-start.sh"
a=$(grep -n 'clock-floor.sh apply' "$KS" | cut -d: -f1); b=$(grep -n 'lxc-start -n knots' "$KS" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ "$a" -lt "$b" ] || fail "knots-start must apply the clock floor before starting the node"
grep -q 'echo "waiting_clock"' "$KS" || fail "knots-start must report waiting_clock"
a=$(grep -n 'bitcoind_ctl_log_clock_wrong; then' "$KS" | cut -d: -f1); b=$(grep -n 'bitcoind_ctl_log_needs_reindex; then' "$KS" | cut -d: -f1)
[ "$a" -lt "$b" ] || fail "knots-start must check the clock before the reindex case"
grep -q 'maintenance_op="waiting_clock"' "$F/usr/libexec/knots/status-api.sh" || fail "status API must show waiting_clock"
grep -q 'op === "waiting_clock"' "$F/www/knots/app.js" || fail "Node Status must explain waiting_clock"
[ -x "$F/etc/hotplug.d/iface/95-knots-ntp" ] && grep -q 'sysntpd restart' "$F/etc/hotplug.d/iface/95-knots-ntp" \
	|| fail "WAN up must restart sysntpd"
[ -x "$F/etc/hotplug.d/ntp/95-knots-node" ] && grep -q 'waiting_clock' "$F/etc/hotplug.d/ntp/95-knots-node" \
	|| fail "NTP sync must start a node that waits for the time"
[ -x "$CF" ] || fail "clock-floor.sh must be executable"
pass "start script, status API, Node Status and NTP / WAN hotplug wired"
echo "ALL PASS: test-clock-floor (T-CLOCK)"
