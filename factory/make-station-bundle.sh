#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Assemble the factory station bundle (make factory-station): the production
# scripts and runbook, build/version.env (the version the scripts expect) and
# the SD / sysupgrade / GPT images of the current build with their SHA256 list.
# No keys: the station makes its own (factory/station-setup.sh).
# Usage: factory/make-station-bundle.sh [OUT_DIR]   (default bin/factory-station)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUT="${1:-$ROOT/bin/factory-station}"
OV=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env")
KV=$(sed -n 's/^KNOTS_VER := //p' "$ROOT/build/version.env")
BN=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env")
VER="$OV.$KV.$BN"; PRE="bpi-r4-phase2-$VER"
SRC="${TARGETS_DIR:-$ROOT/bin/targets/mediatek/filogic}"
B="$OUT/rnode-factory"
[ -f "$SRC/$PRE-sdcard.img.gz" ] || { echo "no SD image for $VER in $SRC (make image)" >&2; exit 1; }

rm -rf "$B"
mkdir -p "$B/factory" "$B/build" "$B/docs" "$B/images/$VER"
for f in "$ROOT"/factory/*.sh "$ROOT"/factory/*.py "$ROOT"/factory/*.md "$ROOT"/factory/emmc-gpt-primary-64.bin; do
	[ -f "$f" ] && cp -p "$f" "$B/factory/"
done
cp -p "$ROOT/build/version.env" "$B/build/"
cp -p "$ROOT/docs/FACTORY_EMMC_INSTALL.md" "$B/docs/" 2>/dev/null || true
for f in "$PRE-sdcard.img.gz" "$PRE-squashfs-sysupgrade.itb" "$PRE-emmc-gpt-primary-64.bin" "$PRE.sha256"; do
	[ -f "$SRC/$f" ] && cp -p "$SRC/$f" "$B/images/$VER/"
done
# A release is installed exactly as signed offline (make store-release puts it
# in Releases/<version>/): the signed sysupgrade image and its SHA256 list
# replace the build output. An unsigned RELEASE=1 build never reaches the station.
REL="$SRC/Releases/$VER"
if [ -f "$REL/$PRE-squashfs-sysupgrade.itb" ]; then
	cp "$REL/$PRE-squashfs-sysupgrade.itb" "$REL/$PRE.sha256" "$B/images/$VER/"
	chmod 644 "$B/images/$VER/$PRE-squashfs-sysupgrade.itb" "$B/images/$VER/$PRE.sha256"
	echo "Station bundle uses the SIGNED release $VER ($(cat "$REL/RELEASE" 2>/dev/null | head -1))"
elif [ "$(cat "$ROOT/files/etc/knots/build_channel" 2>/dev/null)" = release ]; then
	echo "release build $VER is not signed yet — sign it offline, then make store-release" >&2; exit 1
fi
# TFTP install (factory/station): eMMC preloader + BL31/U-Boot FIP of this build
for f in "$SRC"/openwrt-*-bananapi_bpi-r4-emmc-preloader.bin "$SRC"/openwrt-*-bananapi_bpi-r4-emmc-bl31-uboot.fip; do
	[ -f "$f" ] && cp -p "$f" "$B/images/$VER/"
done
( cd "$B/images/$VER" && sha256sum openwrt-*-emmc-preloader.bin openwrt-*-emmc-bl31-uboot.fip >tftp-bootloader.sha256 )
mkdir -p "$B/factory/station/web"
cp -p "$ROOT"/factory/station/*.py "$ROOT"/factory/station/*.sh "$B/factory/station/"
cp -p "$ROOT"/factory/station/web/* "$B/factory/station/web/" 2>/dev/null || true
chmod +x "$B"/factory/*.sh "$B"/factory/*.py "$B"/factory/station/*.py "$B"/factory/station/*.sh
( cd "$B/images/$VER" && sha256sum -c --quiet --ignore-missing "$PRE.sha256" ) || { echo "image SHA256 mismatch" >&2; exit 1; }
find "$B" -name '*.sec' -o -name '*.key' -o -name 'labels*.csv' | grep -q . && { echo "secret in bundle" >&2; exit 1; }
echo "Station bundle: $B  (version $VER, channel $(cat "$ROOT/files/etc/knots/build_channel" 2>/dev/null || echo ?))"
echo "Copy to the station, e.g.: rsync -a $B/ STATION:rnode-factory/"
