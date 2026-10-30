#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# M.2 prepare/mount — REQUIREMENTS S1–S4
# Empty unmarked filesystems get .storage-prepared (no wipe of existing chain data).

set -e

DEVICE="${KNOTS_NVME:-/dev/nvme0n1}"
PART="${DEVICE}p1"
MNT="${KNOTS_MNT:-/mnt/bitcoin}"
DATADIR="${MNT}"
MARKER_PREP="${MNT}/.storage-prepared"
MARKER_FACTORY="${MNT}/.factory-ready"
STATUS_DIR=/tmp/knots
STATUS_FILE="${STATUS_DIR}/storage.status"

log() { logger -t knots-storage "$*"; echo "knots-storage: $*" >&2; }

mkdir -p "$STATUS_DIR"

fail_closed() {
	echo "$1" >"$STATUS_FILE"
	log "FAIL_CLOSED: $*"
	exit 1
}

write_ok() { echo "ok" >"$STATUS_FILE"; }

ensure_fstab() {
	if command -v uci >/dev/null 2>&1; then
		if ! uci -q get fstab.bitcoin >/dev/null; then
			uci set fstab.bitcoin=mount
			uci set fstab.bitcoin.target="$MNT"
			uci set fstab.bitcoin.device="$PART"
			uci set fstab.bitcoin.fstype='ext4'
			# OpenWrt block/ext4 rejects the token "defaults" (EINVAL / "Not a tty")
			uci set fstab.bitcoin.options='noatime'
			uci set fstab.bitcoin.enabled='1'
			uci commit fstab
		fi
	fi
	grep -q " $MNT " /etc/fstab 2>/dev/null || \
		echo "$PART $MNT ext4 noatime 0 2" >>/etc/fstab
}

ensure_layout() {
	mkdir -p "$DATADIR"
	# Adopt empty top-level skeleton as prepared
	if [ ! -f "$MARKER_FACTORY" ] && [ ! -f "$MARKER_PREP" ]; then
		# If blocks dir missing or empty (no blk*.dat), safe to mark prepared
		if [ ! -d "$MNT/blocks" ] || [ -z "$(ls -A "$MNT/blocks" 2>/dev/null | grep -v '^\.' || true)" ]; then
			touch "$MARKER_PREP"
			log "wrote $MARKER_PREP on empty/unmarked filesystem"
		else
			# Has chain data but no marker — adopt as prepared without wipe (dev/migration)
			touch "$MARKER_PREP"
			log "wrote $MARKER_PREP (existing chain data preserved, not wiped)"
		fi
	fi
}

if [ ! -b "$DEVICE" ]; then
	fail_closed "error_no_disk device $DEVICE not found"
fi

mkdir -p "$MNT"

if mountpoint -q "$MNT" 2>/dev/null || grep -qs " $MNT " /proc/mounts; then
	ensure_layout
	ensure_fstab
	write_ok
	log "already mounted"
	exit 0
fi

if [ -b "$PART" ]; then
	if mount -t ext4 "$PART" "$MNT" 2>/dev/null; then
		ensure_layout
		ensure_fstab
		write_ok
		log "mounted existing ext4"
		exit 0
	fi
	# Partition already exists — NEVER fall through to mkfs/parted.
	# A failed mount must fail closed so IBD/chain data cannot be wiped on reflash.
	fail_closed "error_mount existing $PART unmountable (refusing format; factory-image or replace disk)"
fi

# Also refuse wipe if the disk already has a partition table / filesystem signature.
# H6 — blkid is the last guard before the only mkfs in the product: it must exist,
# and a probe that errors (vs. cleanly finding no signatures) is ambiguous — fail
# closed (NF7) instead of proceeding to parted/mkfs on a possibly-live disk.
command -v blkid >/dev/null 2>&1 || fail_closed "error_tools blkid missing"
blkid_out=$(blkid "$DEVICE" 2>"$STATUS_DIR/blkid.err") && blkid_rc=0 || blkid_rc=$?
if [ -s "$STATUS_DIR/blkid.err" ]; then
	log "blkid probe stderr: $(tr '\n' ' ' <"$STATUS_DIR/blkid.err")"
	fail_closed "error_disk $DEVICE blkid probe failed (ambiguous; refusing format)"
fi
if [ "$blkid_rc" -eq 0 ] && printf '%s\n' "$blkid_out" | grep -qE 'TYPE=|PTTYPE='; then
	fail_closed "error_disk $DEVICE has existing signatures (refusing format; factory-image or replace disk)"
fi

log "preparing new filesystem on $DEVICE"
command -v parted >/dev/null 2>&1 || fail_closed "error_tools parted missing"
command -v mkfs.ext4 >/dev/null 2>&1 || fail_closed "error_tools mkfs.ext4 missing"

umount "$MNT" 2>/dev/null || true
parted -s "$DEVICE" mklabel gpt
parted -s "$DEVICE" mkpart primary ext4 1MiB 100%
i=0
while [ ! -b "$PART" ] && [ "$i" -lt 20 ]; do
	sleep 0.5
	i=$((i + 1))
done
[ -b "$PART" ] || fail_closed "error_part partition $PART missing"

# M12a — write an error status on failure so UI/LED see the truth (not stale/absent)
mkfs.ext4 -F -L knots-data "$PART" || fail_closed "error_mkfs mkfs.ext4 failed on $PART"
mount -t ext4 "$PART" "$MNT" || fail_closed "error_mount fresh $PART unmountable"
mkdir -p "$DATADIR"
touch "$MARKER_PREP"
ensure_fstab
write_ok
log "prepared and mounted $PART at $MNT"
exit 0
