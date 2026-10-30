#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# P4 / D3 — flash a captured M.2 data image onto a blank target NVMe.
#
# Usage:
#   ./factory/flash-m2.sh --mode datadir --image ./out/m2-data.tar.zst --device /dev/nvme0n1
#   ./factory/flash-m2.sh --mode disk --image ./out/m2-disk.img.zst --device /dev/nvme0n1
#
# Safety (H5): refuses the disk hosting the running root filesystem, refuses
# disks with any mounted partition, echoes device model/size, and verifies a
# ${IMAGE}.sha256 sidecar automatically before any destructive write
# (TECH_SPEC §11.2 "verify checksum"). KNOTS_VER env + /tmp/knots/status.json
# are used to enrich a .factory-ready stub when the image lacks one.

set -euo pipefail

MODE=datadir
IMAGE=""
DEVICE=/dev/nvme0n1
CONFIRM=""

usage() {
	echo "Usage: $0 --mode datadir|disk --image PATH --device DEV --confirm FLASH_M2" >&2
	exit 2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--mode) MODE="$2"; shift ;;
		--image) IMAGE="$2"; shift ;;
		--device) DEVICE="$2"; shift ;;
		--confirm) CONFIRM="$2"; shift ;;
		*) usage ;;
	esac
	shift
done

[ -n "$IMAGE" ] || usage
[ "$CONFIRM" = "FLASH_M2" ] || {
	echo "refusing: --confirm FLASH_M2 required (destroys $DEVICE)" >&2
	exit 1
}
[ -b "$DEVICE" ] || { echo "missing $DEVICE" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "missing image $IMAGE" >&2; exit 1; }

# H5a — refuse the disk that hosts the running root filesystem. The default
# DEVICE (/dev/nvme0n1) is a typical workstation boot drive: make the guard real.
root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
root_disk=""
if [ -n "$root_src" ] && [ -b "$root_src" ]; then
	# parent disk of the root partition (nvme0n1p2 → nvme0n1, sda2 → sda, mmcblk0p2 → mmcblk0)
	root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)
	[ -n "$root_disk" ] || root_disk=$(basename "$root_src")
fi
dev_name=$(basename "$DEVICE")
if { [ -n "$root_src" ] && [ "$DEVICE" = "$root_src" ]; } || \
   { [ -n "$root_disk" ] && [ "$dev_name" = "$root_disk" ]; }; then
	echo "refusing: $DEVICE hosts the running root filesystem ($root_src)" >&2
	exit 1
fi

# H5a — refuse when any partition of the target is mounted (never silently umount)
if lsblk -nr -o MOUNTPOINT "$DEVICE" 2>/dev/null | grep -q '[^[:space:]]'; then
	echo "refusing: $DEVICE has mounted partitions — unmount them first:" >&2
	lsblk -nr -o NAME,MOUNTPOINT "$DEVICE" 2>/dev/null | awk 'NF > 1' >&2 || true
	exit 1
fi

# H5b — verify the sidecar checksum before any destructive write (TECH_SPEC §11.2)
if [ -f "${IMAGE}.sha256" ]; then
	echo "Verifying checksum: ${IMAGE}.sha256"
	img_dir=$(dirname "$IMAGE")
	img_base=$(basename "$IMAGE")
	if ! (cd "$img_dir" && sha256sum -c "${img_base}.sha256"); then
		echo "refusing: checksum verification failed for $IMAGE" >&2
		exit 1
	fi
fi

PART="${DEVICE}p1"
# SCSI-style partitions
if [[ "$DEVICE" == /dev/sd* ]] || [[ "$DEVICE" == /dev/vd* ]]; then
	PART="${DEVICE}1"
fi

# H5a — show the operator exactly what is about to be destroyed
dev_desc=$(lsblk -d -n -o MODEL,SIZE "$DEVICE" 2>/dev/null | sed 's/  */ /g' || true)
echo "Flashing $IMAGE → $DEVICE (${dev_desc:-model/size unknown}) (mode=$MODE)"

case "$MODE" in
	disk)
		zstd -dc "$IMAGE" | dd of="$DEVICE" bs=4M status=progress conv=fsync
		sync
		;;
	datadir)
		command -v parted >/dev/null
		command -v mkfs.ext4 >/dev/null
		parted -s "$DEVICE" mklabel gpt
		parted -s "$DEVICE" mkpart primary ext4 1MiB 100%
		sleep 1
		# wait for partition node
		for _ in $(seq 1 20); do
			[ -b "$PART" ] && break
			sleep 0.5
		done
		[ -b "$PART" ] || { echo "partition $PART missing" >&2; exit 1; }
		mkfs.ext4 -F -L knots-data "$PART"
		mnt=$(mktemp -d)
		mount -t ext4 "$PART" "$mnt"
		zstd -dc "$IMAGE" | tar -C "$mnt" -xf -
		# Ensure seal markers present. H5c — when the image carries no
		# .factory-ready, write one with knots_version/tip derived from
		# KNOTS_VER + a prior status dump; log when fields stay unknown.
		if [ ! -f "$mnt/.factory-ready" ]; then
			tip_h="unknown"
			tip_hash="unknown"
			if [ -f /tmp/knots/status.json ]; then
				tip_h=$(sed -n 's/.*"blocks":\([0-9]*\).*/\1/p' /tmp/knots/status.json | head -1)
				tip_hash=$(sed -n 's/.*"best_block_hash":"\([^"]*\)".*/\1/p' /tmp/knots/status.json | head -1)
			fi
			ver="${KNOTS_VER:-unknown}"
			if [ "$ver" = "unknown" ] || [ -z "${tip_h:-}" ]; then
				echo "note: .factory-ready stub fields unknown (no image metadata/sidecar)" >&2
			fi
			cat >"$mnt/.factory-ready" <<EOF
{
  "product": "bpi-r4-knots",
  "knots_version": "${ver}",
  "tip_height": "${tip_h:-unknown}",
  "tip_hash": "${tip_hash:-unknown}",
  "note": "factory flash (image carried no .factory-ready)"
}
EOF
		fi
		touch "$mnt/.storage-prepared"
		sync
		umount "$mnt"
		rmdir "$mnt"
		;;
	*)
		usage
		;;
esac

echo "flash complete — insert M.2 into appliance; first boot runs identity-regen (S6)"
