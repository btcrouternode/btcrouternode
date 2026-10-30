#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# P4 / S5 / D3 — capture M.2 data image from a golden (synced) reference unit.
# Prefer mode A (datadir archive). Mode B = whole-disk dd.
#
# Run on the factory station with the golden M.2 mounted, OR over SSH/serial
# on the golden appliance AFTER stopping bitcoind.
#
# H7b — never capture a live node: copying running blocks/chainstate yields an
# inconsistent LevelDB in the golden image. Refuses when bitcoind appears
# running (process or held .lock) unless --force is given. Disk mode also
# stamps .factory-ready onto the disk before dd so cloned units regenerate
# node identity on first boot (S6).
#
# Usage:
#   ./factory/capture-m2.sh --mode datadir --src /mnt/bitcoin --out ./out/m2-data
#   ./factory/capture-m2.sh --mode disk --device /dev/nvme0n1 --out ./out/m2-disk.img.zst
#   add --force to override the live-bitcoind refusal

set -euo pipefail

MODE=datadir
SRC=/mnt/bitcoin
DEVICE=/dev/nvme0n1
OUT=""
KNOTS_VER="${KNOTS_VER:-unknown}"
FORCE=0

usage() {
	echo "Usage: $0 --mode datadir|disk --out PATH [--src DIR] [--device DEV] [--knots-ver VER] [--force]" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--mode) MODE="$2"; shift ;;
		--src) SRC="$2"; shift ;;
		--device) DEVICE="$2"; shift ;;
		--out) OUT="$2"; shift ;;
		--knots-ver) KNOTS_VER="$2"; shift ;;
		--force) FORCE=1 ;;
		*) usage ;;
	esac
	shift
done

[ -n "$OUT" ] || usage

stamp_factory_ready() {
	local root=$1
	local tip_h tip_hash time_now
	tip_h="unknown"
	tip_hash="unknown"
	# Prefer metadata from a prior status dump if present
	if [ -f /tmp/knots/status.json ]; then
		tip_h=$(sed -n 's/.*"blocks":\([0-9]*\).*/\1/p' /tmp/knots/status.json | head -1)
		tip_hash=$(sed -n 's/.*"best_block_hash":"\([^"]*\)".*/\1/p' /tmp/knots/status.json | head -1)
	fi
	time_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	cat >"${root}/.factory-ready" <<EOF
{
  "product": "bpi-r4-knots",
  "knots_version": "${KNOTS_VER}",
  "tip_height": "${tip_h:-unknown}",
  "tip_hash": "${tip_hash:-unknown}",
  "captured_at": "${time_now}",
  "note": "Cloned identity must be regenerated on first boot (S6)"
}
EOF
}

# True when a bitcoind .lock under $1 exists AND is held (live process).
# A stale .lock left by a clean shutdown is reported and not treated as live.
lock_held() {
	local lf
	for lf in "$1/.lock" "$1/bitcoin/.lock"; do
		[ -f "$lf" ] || continue
		if command -v flock >/dev/null 2>&1; then
			if ! flock -n "$lf" -c true 2>/dev/null; then
				return 0
			fi
			echo "note: stale $lf present but not held (bitcoind not running)" >&2
		else
			# cannot probe — treat presence as live (fail safe)
			return 0
		fi
	done
	return 1
}

# H7b(a) — shared live-bitcoind refusal (process on this host or held lock)
refuse_if_live() {
	local dir=$1
	[ "$FORCE" = "1" ] && return 0
	if pgrep -x bitcoind >/dev/null 2>&1; then
		echo "refusing: bitcoind is running — stop it before capture (or --force)" >&2
		exit 1
	fi
	if lock_held "$dir"; then
		echo "refusing: $dir has a held .lock — bitcoind appears running (or --force)" >&2
		exit 1
	fi
}

# Write the sidecar with a basename-only entry so flash-m2.sh can verify it
# with sha256sum -c from the image's own directory (H5b / TECH_SPEC §11.2).
write_sha256() {
	local file=$1
	(cd "$(dirname "$file")" && sha256sum "$(basename "$file")" | tee "$(basename "$file").sha256")
}

case "$MODE" in
	datadir)
		[ -d "$SRC" ] || { echo "missing src $SRC" >&2; exit 1; }
		refuse_if_live "$SRC"
		mkdir -p "$(dirname "$OUT")"
		work=$(mktemp -d)
		trap 'rm -rf "$work"' EXIT
		# Copy chain data only — never ship node identity / wallets
		mkdir -p "$work/bitcoin"
		if [ -d "$SRC/bitcoin/blocks" ]; then
			cp -a "$SRC/bitcoin/blocks" "$work/bitcoin/"
			cp -a "$SRC/bitcoin/chainstate" "$work/bitcoin/" 2>/dev/null || true
			# optional indexes
			[ -d "$SRC/bitcoin/indexes" ] && cp -a "$SRC/bitcoin/indexes" "$work/bitcoin/" || true
		elif [ -d "$SRC/blocks" ]; then
			# layout variant: blocks at mount root
			mkdir -p "$work/bitcoin"
			cp -a "$SRC/blocks" "$work/bitcoin/"
			cp -a "$SRC/chainstate" "$work/bitcoin/" 2>/dev/null || true
		else
			echo "no blocks/ under $SRC" >&2
			exit 1
		fi
		stamp_factory_ready "$work"
		touch "$work/.storage-prepared"
		# Exclude identity leftovers if any sneaked in
		rm -f "$work/bitcoin/peers.dat" \
			"$work/bitcoin/onion_v3_private_key" \
			"$work/bitcoin/.cookie" \
			"$work/bitcoin/banlist.json" \
			"$work/bitcoin/banlist.dat" 2>/dev/null || true
		rm -rf "$work/bitcoin/wallets" "$work/bitcoin/walletdir" 2>/dev/null || true
		tar -C "$work" -cf - . | zstd -T0 -19 -o "${OUT}.tar.zst"
		write_sha256 "${OUT}.tar.zst"
		echo "captured datadir archive → ${OUT}.tar.zst"
		;;
	disk)
		[ -b "$DEVICE" ] || { echo "missing block device $DEVICE" >&2; exit 1; }
		mkdir -p "$(dirname "$OUT")"
		PART="${DEVICE}p1"
		if [[ "$DEVICE" == /dev/sd* ]] || [[ "$DEVICE" == /dev/vd* ]]; then
			PART="${DEVICE}1"
		fi
		# H7b(b) — mount p1 (read-write) so we can check .lock and stamp
		# .factory-ready before dd; otherwise clones skip identity regen (S6).
		mnt=$(findmnt -n -o TARGET "$PART" 2>/dev/null | head -1 || true)
		we_mounted=0
		if [ -z "$mnt" ]; then
			mnt=$(mktemp -d)
			if ! mount "$PART" "$mnt" 2>/dev/null; then
				rmdir "$mnt"
				echo "cannot mount $PART to stamp .factory-ready — refusing capture (S6)" >&2
				exit 1
			fi
			we_mounted=1
		fi
		refuse_live_rc=0
		if [ "$FORCE" != "1" ]; then
			if pgrep -x bitcoind >/dev/null 2>&1; then
				echo "refusing: bitcoind is running — stop it before capture (or --force)" >&2
				refuse_live_rc=1
			elif lock_held "$mnt"; then
				echo "refusing: $PART has a held .lock — bitcoind appears running (or --force)" >&2
				refuse_live_rc=1
			fi
		fi
		if [ "$refuse_live_rc" = "1" ]; then
			if [ "$we_mounted" = "1" ]; then umount "$mnt"; rmdir "$mnt"; fi
			exit 1
		fi
		if [ ! -w "$mnt" ]; then
			if [ "$we_mounted" = "1" ]; then umount "$mnt"; rmdir "$mnt"; fi
			echo "cannot stamp .factory-ready: $mnt is read-only — refusing capture (S6)" >&2
			exit 1
		fi
		if ! stamp_factory_ready "$mnt"; then
			if [ "$we_mounted" = "1" ]; then umount "$mnt"; rmdir "$mnt"; fi
			echo "failed to stamp .factory-ready on $PART — refusing capture (S6)" >&2
			exit 1
		fi
		touch "$mnt/.storage-prepared"
		sync
		if [ "$we_mounted" = "1" ]; then
			umount "$mnt"
			rmdir "$mnt"
		fi
		dd if="$DEVICE" bs=4M status=progress | zstd -T0 -19 -o "${OUT}.img.zst"
		write_sha256 "${OUT}.img.zst"
		echo "captured disk image → ${OUT}.img.zst"
		;;
	*)
		usage
		;;
esac
