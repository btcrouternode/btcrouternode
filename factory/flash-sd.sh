#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Write the product SD image to a microSD card — `make flash-sd` (T4, review
# 2026-10-11). Project rule: "All mkfs/parted/dd paths gated by explicit
# confirm + device assertion". The old Makefile target printed "CONFIRM" and
# went straight to `sudo dd` on whatever DEVICE= said.
#
# Refuses: partitions (sdb1), non-block / missing devices, non-removable disks
# that are not USB/SD readers, any disk with a mounted partition or swap (the
# system disk always is), sizes outside 2–256 GiB. Then shows the device and
# asks you to TYPE its name (e.g. "sdb") — nothing else confirms.
#
# Usage: factory/flash-sd.sh DEVICE IMAGE.img.gz
# Env:   CONFIRM_DEVICE=sdb   non-interactive confirmation (must equal the name)
#        SYS_BLOCK=/sys/block MOUNTS=/proc/mounts SWAPS=/proc/swaps DRY_RUN=1 (tests)
set -euo pipefail
DEV="${1:-}"
IMG="${2:-}"
SYS_BLOCK="${SYS_BLOCK:-/sys/block}"
MOUNTS="${MOUNTS:-/proc/mounts}"
SWAPS="${SWAPS:-/proc/swaps}"
die() { echo "ERROR: $*" >&2; exit 1; }

[ -n "$DEV" ] && [ -n "$IMG" ] || die "usage: make flash-sd DEVICE=/dev/sdX"
[ -f "$IMG" ] || die "$IMG missing — run 'make image' first"
case "$DEV" in /dev/*) ;; *) die "DEVICE must be a /dev path (got $DEV)" ;; esac
NAME="${DEV#/dev/}"
case "$NAME" in
	*/*|"") die "unsupported device path $DEV" ;;
esac
[ -d "$SYS_BLOCK/$NAME" ] || die "$DEV is not a whole disk (partitions like sdb1 / mmcblk0p1 are refused; use the disk, e.g. /dev/sdb)"
[ "${DRY_RUN:-0}" = 1 ] || [ -b "$DEV" ] || die "$DEV is not a block device"

# Removable media only: SD/USB readers report removable=1 or sit on USB;
# built-in SD slots are mmcblk*. Internal SATA/NVMe disks are refused.
removable=$(cat "$SYS_BLOCK/$NAME/removable" 2>/dev/null || echo 0)
usb=0
readlink -f "$SYS_BLOCK/$NAME" 2>/dev/null | grep -q '/usb[0-9]*/' && usb=1
case "$NAME" in
	mmcblk[0-9]*) ;;
	nvme*|md*|dm-*|loop*|zram*) die "$DEV is not an SD card ($NAME devices are refused)" ;;
	*) [ "$removable" = 1 ] || [ "$usb" = 1 ] || die "$DEV is not removable and not on USB — refusing (system/internal disk?)" ;;
esac

# Nothing on it may be in use (the running system's disk always is).
inuse=$(awk -v d="/dev/$NAME" 'index($1, d) == 1 { print $1 " on " $2 }' "$MOUNTS" 2>/dev/null || true)
[ -z "$inuse" ] || die "$DEV has mounted partitions — unmount them first:
$inuse"
awk -v d="/dev/$NAME" 'index($1, d) == 1 { f = 1 } END { exit !f }' "$SWAPS" 2>/dev/null \
	&& die "$DEV holds active swap — refusing"

sectors=$(cat "$SYS_BLOCK/$NAME/size" 2>/dev/null || echo 0)
gib=$(( sectors * 512 / 1024 / 1024 / 1024 ))
[ "$gib" -ge 2 ] && [ "$gib" -le 256 ] || die "$DEV is ${gib} GiB — outside 2–256 GiB, not an SD card"

model=$(cat "$SYS_BLOCK/$NAME/device/model" 2>/dev/null | tr -s ' ' || true)
vendor=$(cat "$SYS_BLOCK/$NAME/device/vendor" 2>/dev/null | tr -s ' ' || true)
echo "Target : $DEV  ${vendor}${model:+ $model}  ${gib} GiB  removable=$removable usb=$usb"
echo "Image  : $IMG"
echo "ALL DATA ON $DEV WILL BE DESTROYED."
if [ -n "${CONFIRM_DEVICE:-}" ]; then
	answer=$CONFIRM_DEVICE
else
	[ -r /dev/tty ] || die "no terminal to confirm — set CONFIRM_DEVICE=$NAME to confirm explicitly"
	printf 'Type the device name (%s) to continue: ' "$NAME" >/dev/tty
	read -r answer </dev/tty
fi
[ "$answer" = "$NAME" ] || die "confirmation did not match '$NAME' — nothing written"

if [ "${DRY_RUN:-0}" = 1 ]; then
	echo "DRY_RUN: would write $IMG -> $DEV"
	exit 0
fi
gzip -dc "$IMG" | sudo dd of="$DEV" bs=4M status=progress conv=fsync
sync
echo "Done: $DEV — remove the card and insert it in the router (DIP SW3 A=1 B=1)."
