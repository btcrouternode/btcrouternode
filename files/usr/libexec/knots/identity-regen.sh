#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Regenerate node identity on factory-cloned datadir (P4 / S6).
# Safe no-op if not factory-sealed or already done on this system image.

set -e

DATADIR="${KNOTS_DATADIR:-/mnt/bitcoin/bitcoin}"
MNT="${KNOTS_MNT:-/mnt/bitcoin}"
FLAG=/etc/knots/identity-regen.done
# H7a/B9 — mirror the done-marker on the M.2 itself: a wiped overlay (jffs2reset)
# must not re-run regen and delete wallets on a disk whose identity was already
# regenerated. Done if EITHER marker exists; /etc/knots flag kept for compat.
M2_FLAG="${MNT}/.identity-regen.done"
MARKER="${MNT}/.factory-ready"

[ -f "$MARKER" ] || exit 0
[ -f "$FLAG" ] && exit 0
[ -f "$M2_FLAG" ] && exit 0

mkdir -p /etc/knots
# Support both layouts: datadir under /mnt/bitcoin/bitcoin or mount-root blocks/
for d in "$DATADIR" "$MNT"; do
	[ -d "$d" ] || continue
	rm -f "$d/peers.dat" \
		"$d/onion_v3_private_key" \
		"$d/.cookie" \
		"$d/banlist.json" \
		"$d/banlist.dat" 2>/dev/null || true
	rm -rf "$d/walletdir" "$d/wallets" 2>/dev/null || true
done

# Cookie may also live at mount root (appliance layout)
rm -f "${MNT}/.cookie" 2>/dev/null || true

touch "$FLAG"
# Mirror onto the M.2 (H7a/B9) — only reachable when .factory-ready was seen,
# i.e. the real disk view; ignore failure so a read-only mount cannot abort.
touch "$M2_FLAG" 2>/dev/null || true
logger -t knots-identity "regenerated node identity material (S6)"
exit 0

