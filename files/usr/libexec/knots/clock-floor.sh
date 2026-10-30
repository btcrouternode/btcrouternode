#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Never let the router's clock be earlier than its own Bitcoin data.
#
# The BPI-R4 has no RTC battery: until NTP answers (internet needed) the clock
# starts from OpenWrt's newest /etc file — after a factory install or reset
# that is the firmware BUILD date. bitcoind then sees blocks "from the future"
# and refuses to start ("restart with -reindex") — router B on .104–.107 looked
# like a damaged chain for days; the chain was fine, the clock was months behind.
#
#   clock-floor.sh apply   clock behind the newest M.2 data → set it forward
#   clock-floor.sh stamp   record "the clock was right at this time" on the M.2
#   clock-floor.sh floor   print the floor (epoch seconds; 0 if none)
set -u
DATA="${KNOTS_DATADIR:-/mnt/bitcoin}"
STAMP="$DATA/.clock-stamp"

mtime() { [ -e "$1" ] && date -r "$1" +%s 2>/dev/null || echo 0; }

floor() {
	f=0
	# Written only while the clock is known good (NTP sync, or a running node).
	for p in "$STAMP" "$DATA/peers.dat" "$DATA/mempool.dat" "$DATA/fee_estimates.dat" "$DATA/blocks"; do
		t=$(mtime "$p")
		[ "$t" -gt "$f" ] 2>/dev/null && f=$t
	done
	# The newest block file: its last write is about the newest block's time.
	newest=$(ls -t "$DATA"/blocks/blk*.dat 2>/dev/null | head -n 1)
	if [ -n "$newest" ]; then
		t=$(mtime "$newest")
		[ "$t" -gt "$f" ] 2>/dev/null && f=$t
	fi
	echo "$f"
}

case "${1:-apply}" in
	floor) floor ;;
	apply)
		grep -q " $DATA " /proc/mounts 2>/dev/null || [ -n "${KNOTS_DATADIR:-}" ] || exit 0
		f=$(floor); now=$(date +%s)
		if [ "$f" -gt "$now" ] 2>/dev/null; then
			date -u -s "$(date -u -d "@$f" '+%Y-%m-%d %H:%M:%S')" >/dev/null 2>&1 || exit 1
			logger -t knots-clock "clock was behind the node's data: set forward to $(date -u '+%Y-%m-%d %H:%M:%S') UTC (NTP corrects it when online)" 2>/dev/null || true
			echo "set-forward"
		fi
		;;
	stamp)
		grep -q " $DATA " /proc/mounts 2>/dev/null || [ -n "${KNOTS_DATADIR:-}" ] || exit 0
		f=$(floor); now=$(date +%s)
		# Only a clock that is not behind the data may stamp (never record a wrong time).
		[ "$now" -ge "$f" ] 2>/dev/null && touch "$STAMP" 2>/dev/null
		;;
	*) echo "usage: clock-floor.sh apply|stamp|floor" >&2; exit 2 ;;
esac
exit 0
