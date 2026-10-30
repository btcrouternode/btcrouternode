#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Sign one sysupgrade image in place with a usign SECRET key and print its new
# SHA256 (the SHA testers paste is of the SIGNED file). The signature is
# appended as an fwtool chunk that the router strips and verifies
# (files/usr/libexec/knots/release-sig.sh). Used by build/sign-release.sh and,
# for releases, on the offline laptop from the tools stick.
# Usage: sign-image.sh SECRET_KEY IMAGE.itb
set -eu
KEY="${1:?usage: sign-image.sh SECRET_KEY IMAGE}"
IMG="${2:?usage: sign-image.sh SECRET_KEY IMAGE}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${HOST_BIN:-}" ]; then
	if [ -x "$HERE/usign/bin/usign" ]; then HOST_BIN="$HERE/usign/bin"
	else HOST_BIN="$HERE/../build/imagebuilder/staging_dir/host/bin"; fi
fi
[ -f "$KEY" ] || { echo "no secret key at $KEY" >&2; exit 1; }
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
SIG=$(mktemp); OLD=$(mktemp)
trap 'rm -f "$SIG" "$OLD"' EXIT
rm -f "$OLD"
fp=$("$HOST_BIN/usign" -F -s "$KEY")
# Image Builder output already ends in OpenWrt's own build-key signature; ours
# goes on top (the router strips only the outermost one, restoring the exact
# built image). Refuse only a second signature with the same key.
"$HOST_BIN/fwtool" -q -s "$OLD" "$IMG" >/dev/null 2>&1 || true
if [ -s "$OLD" ] && grep -aq "signed by key $fp" "$OLD"; then
	echo "$IMG is already signed with key $fp — refusing to sign twice" >&2; exit 1
fi
"$HOST_BIN/usign" -S -m "$IMG" -s "$KEY" -x "$SIG"
"$HOST_BIN/fwtool" -S "$SIG" "$IMG"
echo "Signed $(basename "$IMG") with key $fp"
sha256sum "$IMG" | sed 's|  .*/|  |'
