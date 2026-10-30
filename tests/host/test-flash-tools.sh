#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-FLASH-TOOLS — review Phase 7 (2026-10-11).
#  T4  make flash-sd → factory/flash-sd.sh: whole removable disk only, nothing
#      mounted / no swap, SD-sized, typed device-name confirmation. Exercised
#      against a fake /sys/block tree with DRY_RUN=1 — nothing is written.
#  T3  flash-nand-from-sd-menu7.sh is phase 1 of install-emmc-from-sd.sh (no
#      blind "7", no "any Press ENTER = success"); --to-phase works.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FS="$ROOT/factory/flash-sd.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
echo x | gzip >"$W/img.gz"
mkdisk() { # NAME removable size_sectors [usb]
	mkdir -p "$W/sys/$1/device"
	echo "$2" >"$W/sys/$1/removable"; echo "$3" >"$W/sys/$1/size"
	echo "TestCard" >"$W/sys/$1/device/model"
}
mkdisk sdb 1 62333952           # 29.7 GiB removable reader
mkdisk sda 0 976773168          # 465 GiB internal SATA
mkdisk sdc 1 62333952           # removable but mounted
mkdisk sdd 1 2048000            # 1 GiB — too small
mkdisk mmcblk0 0 62333952       # built-in SD slot
mkdisk nvme0n1 0 1953525168
: >"$W/swaps"
printf '/dev/sda2 / ext4 rw 0 0\n/dev/sdc1 /media/x vfat rw 0 0\n' >"$W/mounts"
fs() { DRY_RUN=1 SYS_BLOCK="$W/sys" MOUNTS="$W/mounts" SWAPS="$W/swaps" bash "$FS" "$@" </dev/null >"$W/out" 2>&1; }

CONFIRM_DEVICE=sdb fs /dev/sdb "$W/img.gz" || { cat "$W/out"; fail "removable SD must be accepted"; }
grep -q 'DRY_RUN: would write' "$W/out" || fail "dry run must stop before dd"
CONFIRM_DEVICE=mmcblk0 fs /dev/mmcblk0 "$W/img.gz" || { cat "$W/out"; fail "built-in SD slot must be accepted"; }
pass "removable / built-in SD accepted with typed confirmation"

refuse() { # why DEVICE [CONFIRM]
	why=$1; shift
	if CONFIRM_DEVICE="${2:-${1#/dev/}}" fs "$1" "$W/img.gz"; then fail "must refuse: $why"; fi
	grep -q 'DRY_RUN' "$W/out" && fail "refused case reached the write: $why"
	true
}
refuse "internal disk (system)" /dev/sda
refuse "partition" /dev/sdb1
refuse "mounted partition" /dev/sdc
refuse "too small" /dev/sdd
refuse "nvme" /dev/nvme0n1
refuse "wrong confirmation" /dev/sdb sda
refuse "missing device" /dev/sdz
refuse "no DEVICE" ""
printf '/dev/sdb2 partition 1 0 -2\n' >"$W/swaps"
refuse "swap on the card" /dev/sdb
: >"$W/swaps"
pass "refused: system/internal disk, partition, mounted, swap, wrong size, nvme, bad confirmation"

grep -q 'factory/flash-sd.sh' "$ROOT/Makefile" || fail "make flash-sd must use factory/flash-sd.sh"
awk '/^flash-sd:/,/^$/' "$ROOT/Makefile" | grep -q 'sudo dd' && fail "Makefile must not dd directly"
pass "T4 make flash-sd → guarded script"

# --- T3
M="$ROOT/factory/flash-nand-from-sd-menu7.sh"
grep -q 'install-emmc-from-sd.sh" --from-phase 1 --to-phase 1' "$M" || fail "menu-7 helper must run installer phase 1 only"
grep -qE "b'7|\"7\\\\n\"|send_raw" "$M" && fail "menu-7 helper must not send 7 blind"
I="$ROOT/factory/install-emmc-from-sd.sh"
bash -n "$I" || fail "installer syntax"
awk "/<< 'PY'\$/{f=1;next} /^PY\$/{f=0} f" "$I" >"$W/inst.py"
python3 -m py_compile "$W/inst.py" || fail "installer python syntax"
grep -q 'START_PHASE <= n <= END_PHASE' "$W/inst.py" || fail "--to-phase must bound the phase loop"
out=$(PORT=/nonexistent bash "$I" --from-phase 2 --to-phase 1 2>&1) && fail "--to-phase < --from-phase must be refused"
printf '%s' "$out" | grep -q 'to-phase must be >= --from-phase' || fail "bad range message: $out"
grep -q "install.\*\\\\bnand\\\\b" "$W/inst.py" || fail "phase 1 must parse the NAND menu entry"
grep -q "'Installation abort'" "$W/inst.py" || fail "phase 1 must detect install failure"
pass "T3 menu-7 helper = guarded installer phase 1; --to-phase validated"

echo "ALL PASS: test-flash-tools (T-FLASH-TOOLS)"
