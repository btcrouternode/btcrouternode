#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Sign a published sysupgrade image with the release key and refresh its
# .sha256 line (the SHA testers paste is of the SIGNED file).
# usign signs the image as built; the signature is appended as an fwtool chunk
# that the router strips and verifies (files/usr/libexec/knots/release-sig.sh).
#
# Usage: build/sign-release.sh SECRET_KEY [targets-dir]
#   (make sign-release KEY=…; test builds: done by `make image` with the TEST key)
# The signing itself is factory/sign-image.sh (also on the offline tools stick).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY="${1:?usage: sign-release.sh SECRET_KEY [targets-dir]}"
DIR="${2:-$ROOT/bin/targets/mediatek/filogic}"
H="${HOST_BIN:-$ROOT/build/imagebuilder/staging_dir/host/bin}"
OV=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env")
KV=$(sed -n 's/^KNOTS_VER := //p' "$ROOT/build/version.env")
BN=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env")
PRE="bpi-r4-phase2-${OV}.${KV}.${BN}"
IMG="$DIR/${PRE}-squashfs-sysupgrade.itb"
SUM="$DIR/${PRE}.sha256"
[ -f "$KEY" ] || { echo "no secret key at $KEY" >&2; exit 1; }
[ -f "$IMG" ] || { echo "no image $IMG (make image first)" >&2; exit 1; }
HOST_BIN="$H" "$ROOT/factory/sign-image.sh" "$KEY" "$IMG" >/dev/null
fp=$("$H/usign" -F -s "$KEY")
( cd "$DIR"
  { sha256sum "$(basename "$IMG")"
    grep -v -- "-squashfs-sysupgrade.itb\$" "$(basename "$SUM")" || true; } >"$(basename "$SUM").new"
  mv "$(basename "$SUM").new" "$(basename "$SUM")" )
echo "Signed $(basename "$IMG") with key $fp"
grep -- "-squashfs-sysupgrade.itb" "$SUM"
