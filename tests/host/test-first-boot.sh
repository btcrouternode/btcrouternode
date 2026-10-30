#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-FIRST-BOOT — first-boot scripts must never hold back networking, Wi-Fi,
# DHCP and the web UI (uci-defaults run inside S10boot). .104 dry run: a
# labelled unit had no Wi-Fi / Setup for minutes after a power cycle because
# 99-bitcoin-node waited for bitcoind's RPC (chainstate replay).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
for f in "$ROOT"/files/etc/uci-defaults/*; do
	# every knots-start.sh start / bitcoind wait must be inside a backgrounded subshell
	awk -v F="${f##*/}" '
		/^[[:space:]]*#/ { next }
		/\(/ { depth += gsub(/\(/, "(") }
		/knots-start\.sh start|bitcoin-cli|rpc_ok/ && depth == 0 { print F ": " $0; bad = 1 }
		/\)/ { depth -= gsub(/\)/, ")") }
		END { exit bad }' "$f" || fail "uci-defaults script waits for the node in the foreground (see above)"
done
grep -q 'knots-start.sh start' "$ROOT/files/etc/uci-defaults/99-bitcoin-node" || fail "99-bitcoin-node must still start the node"
grep -qF ') >/tmp/knots-start-first.log 2>&1 </dev/null &' "$ROOT/files/etc/uci-defaults/99-bitcoin-node" || fail "first start must be backgrounded"
echo "PASS: first-boot scripts start the node in the background (boot never waits for bitcoind)"
echo "ALL PASS: test-first-boot (T-FIRST-BOOT)"
