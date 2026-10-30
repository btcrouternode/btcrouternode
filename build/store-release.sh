#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# File a release that was signed offline with key A (or B) next to the builds:
#   bin/targets/mediatek/filogic/Releases/<product_version>/
# Refuses anything not signed by a key in keys/release (the TEST key does not
# count), a build that was not made with RELEASE=1, and overwriting a release.
# Usage: store-release.sh SIGNED_SYSUPGRADE.itb   (make store-release SIGNED=…)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SIGNED="${1:?usage: store-release.sh SIGNED_SYSUPGRADE.itb}"
DIR="${TARGETS_DIR:-$ROOT/bin/targets/mediatek/filogic}"
H="${HOST_BIN:-$ROOT/build/imagebuilder/staging_dir/host/bin}"
KEYS="${KNOTS_KEYS_DIR:-$ROOT/keys}/release"
OV=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env")
KV=$(sed -n 's/^CORE_VER := //p' "$ROOT/build/version.env")
BN=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env")
VER="$OV.$KV.$BN"; PRE="bpi-r4-phase2-$VER"
fail() { echo "store-release: $*" >&2; exit 1; }

[ -f "$SIGNED" ] || fail "no file $SIGNED"
[ "$(cat "${BUILD_CHANNEL_FILE:-$ROOT/files/etc/knots/build_channel}" 2>/dev/null)" = release ] \
	|| fail "the current build is not a release build (make image RELEASE=1)"
BUILT="$DIR/$PRE-squashfs-sysupgrade.itb"
[ -f "$BUILT" ] || fail "no build $BUILT"
# Verify exactly like the router: strip the outermost signature, verify it
# against the RELEASE keys only, and the stripped image must be this build.
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
cp "$SIGNED" "$W/img"
"$H/fwtool" -q -t -s "$W/sig" "$W/img" >/dev/null 2>&1 || true
[ -s "$W/sig" ] || fail "$SIGNED carries no signature"
"$H/usign" -V -q -m "$W/img" -P "$KEYS" -x "$W/sig" || fail "signature is not from release key A or B"
cmp -s "$W/img" "$BUILT" || fail "signed file is not build $VER (sign the image from this build)"
fp=$(grep -ao 'signed by key [0-9a-f]*' "$W/sig" | head -1 | awk '{print $4}')

R="$DIR/Releases/$VER"
[ ! -e "$R" ] || fail "release $VER already stored in $R"
mkdir -p "$R"
cp "$SIGNED" "$R/$PRE-squashfs-sysupgrade.itb"
for f in "$PRE-sdcard.img.gz" "$PRE-emmc-gpt-primary-64.bin"; do
	[ -f "$DIR/$f" ] && cp "$DIR/$f" "$R/"
done
( cd "$R" && sha256sum $(ls | grep -E '\.(itb|gz|bin)$') >"$PRE.sha256" )
printf 'version=%s\nsigned_by=%s\nstored=%s\n' "$VER" "$fp" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$R/RELEASE"
chmod -R a-w "$R"
echo "Stored release $VER (signed by $fp) in $R"
cat "$R/$PRE.sha256"
