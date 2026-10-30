#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Publish versioned copies of Image Builder artifacts (PRODUCT_VER in filename).
# Keeps stock OpenWrt names; adds bpi-r4-phase2-<PRODUCT_VER>-* for Settings / releases.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENWRT_VER=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env" | head -1)
KNOTS_VER=$(sed -n 's/^KNOTS_VER := //p' "$ROOT/build/version.env" | head -1)
BUILD_NUM=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env" | head -1)
PROFILE=$(sed -n 's/^PROFILE := //p' "$ROOT/build/version.env" | head -1)
PARTSIZE=$(sed -n 's/^ROOTFS_PARTSIZE_MIB := //p' "$ROOT/build/version.env" | head -1)
PRODUCT_VER="${OPENWRT_VER}.${KNOTS_VER}.${BUILD_NUM}"

DIR="${1:-$ROOT/bin/targets/mediatek/filogic}"
[[ -d "$DIR" ]] || { echo "FAIL: missing targets dir $DIR"; exit 1; }
[[ -n "$PRODUCT_VER" && -n "$PROFILE" ]] || { echo "FAIL: bad version.env"; exit 1; }

STOCK_UPG=$(ls -1 "$DIR"/openwrt-*-mediatek-filogic-"$PROFILE"-squashfs-sysupgrade.itb 2>/dev/null | head -1 || true)
STOCK_SD=$(ls -1 "$DIR"/openwrt-*-mediatek-filogic-"$PROFILE"-sdcard.img.gz 2>/dev/null | head -1 || true)
[[ -n "$STOCK_UPG" && -f "$STOCK_UPG" ]] || {
  echo "FAIL: no stock *-${PROFILE}-squashfs-sysupgrade.itb in $DIR"
  exit 1
}

VER_PREFIX="bpi-r4-phase2-${PRODUCT_VER}"
VER_UPG="${DIR}/${VER_PREFIX}-squashfs-sysupgrade.itb"
VER_SD="${DIR}/${VER_PREFIX}-sdcard.img.gz"
VER_SUM="${DIR}/${VER_PREFIX}.sha256"
VER_GPT="${DIR}/${VER_PREFIX}-emmc-gpt-primary-64.bin"

cp -f "$STOCK_UPG" "$VER_UPG"
echo "Published $(basename "$VER_UPG")"

if [[ -n "$STOCK_SD" && -f "$STOCK_SD" ]]; then
  cp -f "$STOCK_SD" "$VER_SD"
  echo "Published $(basename "$VER_SD")"
  # G4/D6: the eMMC primary GPT is generated from THIS image and verified
  # (layout, CRCs, LBAs vs ROOTFS_PARTSIZE_MIB, committed reference copy).
  python3 -I "$ROOT/build/extract-emmc-gpt.py" "$VER_SD" "$PARTSIZE" "$VER_GPT" \
    "$ROOT/factory/emmc-gpt-primary-64.bin"
else
  VER_SD=""
  VER_GPT=""
fi

(
  cd "$DIR"
  {
    sha256sum "$(basename "$VER_UPG")"
    if [[ -n "$VER_SD" ]]; then
      sha256sum "$(basename "$VER_SD")"
    fi
    if [[ -n "$VER_GPT" ]]; then
      sha256sum "$(basename "$VER_GPT")"
    fi
  } >"$(basename "$VER_SUM")"
)

echo "Checksums → $(basename "$VER_SUM")"
echo "PRODUCT_VER=$PRODUCT_VER"
ls -lh "$VER_UPG" ${VER_SD:+"$VER_SD"} ${VER_GPT:+"$VER_GPT"} "$VER_SUM"
