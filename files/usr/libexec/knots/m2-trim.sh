#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Weekly TRIM of the blockchain M.2 (owner decision 2026-10-22). fstrim tells
# the SSD which blocks ext4 has ALREADY freed (rewritten chainstate files,
# mempool/fee files, logs) so the drive can erase them in the background. It
# never touches existing files — the chain stays complete (prune=0) — and is
# not the always-on `discard` mount option (that slows every delete).
#
# Run by the knots-status loop every 15 s; does the work at most once a week,
# only between 02:00 and 05:59 router time (a router that was off catches up
# the next night), never while a node operation is running.
# Paths / clock overridable for tests.
set -u
MNT="${KNOTS_MNT:-/mnt/bitcoin}"
MOUNTS="${KNOTS_MOUNTS:-/proc/mounts}"
OUT_DIR="${KNOTS_STATUS_DIR:-/tmp/knots}"
FSTRIM="${FSTRIM:-fstrim}"
NOW="${KNOTS_NOW:-$(date +%s)}"
HOUR="${KNOTS_HOUR:-$(date +%H)}"
WEEK=$((7 * 86400 - 3600))

case "${HOUR#0}" in 2|3|4|5) ;; *) exit 0 ;; esac
grep -q " $MNT ext4 rw" "$MOUNTS" 2>/dev/null || exit 0
STAMP="$MNT/.disk-health/last-trim"
last=$(sed -n 's/^ts=//p' "$STAMP" 2>/dev/null); case "$last" in ''|*[!0-9]*) last=0 ;; esac
[ $((NOW - last)) -ge "$WEEK" ] || exit 0
# Busy check in a subshell: node-impl-lib.sh sets its own MNT and helpers,
# which must not leak into this script (found on hardware, .101).
LIB="${KNOTS_NODE_LIB:-/usr/libexec/knots/node-impl-lib.sh}"
if [ -f "$LIB" ]; then
	# shellcheck disable=SC1090
	case "$( . "$LIB" >/dev/null 2>&1; read_node_busy 2>/dev/null )" in true*) exit 0 ;; esac
fi
command -v "$FSTRIM" >/dev/null 2>&1 || { logger -t knots-trim "fstrim not installed" 2>/dev/null; exit 0; }

mkdir -p "$MNT/.disk-health" "$OUT_DIR"
t0=$(date +%s)
if out=$(nice -n 19 "$FSTRIM" -v "$MNT" 2>&1); then rc=0; else rc=$?; fi
secs=$(( $(date +%s) - t0 ))
out=$(printf '%s' "$out" | tr -d '\r' | head -1 | sed 's/"/'"'"'/g')
logger -t knots-trim "fstrim $MNT rc=$rc ${secs}s: $out" 2>/dev/null || true
# Stamp even on failure so a drive that rejects TRIM is not retried every 15 s.
printf 'ts=%s\nrc=%s\nsecs=%s\nresult=%s\n' "$NOW" "$rc" "$secs" "$out" >"$STAMP"
printf '{"ts":%s,"rc":%s,"secs":%s,"result":"%s"}\n' "$NOW" "$rc" "$secs" "$out" >"$OUT_DIR/m2-trim.json"
exit 0
