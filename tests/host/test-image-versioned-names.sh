#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-IMG-VER — versioned image filenames include PRODUCT_VER (R1a / U13)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/build/publish-versioned-images.sh"
MK="$ROOT/Makefile"

[ -f "$SCRIPT" ] || { echo "FAIL: missing publish-versioned-images.sh"; exit 1; }
grep -q 'publish-versioned-images.sh' "$MK" || {
	echo "FAIL: Makefile image target must publish versioned names"; exit 1
}
grep -q 'bpi-r4-phase2-' "$SCRIPT" || {
	echo "FAIL: publish script must use bpi-r4-phase2- prefix"; exit 1
}
grep -q 'PRODUCT_VER' "$SCRIPT" || {
	echo "FAIL: publish script must embed PRODUCT_VER"; exit 1
}

# If a bake exists, require versioned sysupgrade present
DIR="$ROOT/bin/targets/mediatek/filogic"
if [ -d "$DIR" ] && ls "$DIR"/openwrt-*-squashfs-sysupgrade.itb >/dev/null 2>&1; then
	OPENWRT_VER=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env" | head -1)
	CORE_VER=$(sed -n 's/^CORE_VER := //p' "$ROOT/build/version.env" | head -1)
	BUILD_NUM=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env" | head -1)
	PV="${OPENWRT_VER}.${CORE_VER}.${BUILD_NUM}"
	[ -f "$DIR/bpi-r4-phase2-${PV}-squashfs-sysupgrade.itb" ] || {
		echo "FAIL: missing bpi-r4-phase2-${PV}-squashfs-sysupgrade.itb (run publish script)"
		exit 1
	}
	[ -f "$DIR/bpi-r4-phase2-${PV}.sha256" ] || {
		echo "FAIL: missing bpi-r4-phase2-${PV}.sha256"; exit 1
	}
	echo "OK versioned artifact for $PV"
fi

echo "PASS T-IMG-VER"
