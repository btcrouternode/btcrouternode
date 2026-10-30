#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Stage the trusted release keys into the firmware overlay (keys/README.md).
#   test    — release A/B + the TEST key (UAT/soak builds, signed on this PC)
#   release — release A/B only (signed offline with key A)
# Writes FILES_DIR/etc/knots/build_channel. Usage: stage-release-keys.sh FILES_DIR test|release
set -eu
FILES="${1:?usage: stage-release-keys.sh FILES_DIR test|release}"
CH="${2:?usage: stage-release-keys.sh FILES_DIR test|release}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KEYS="${KNOTS_KEYS_DIR:-$ROOT/keys}"
case "$CH" in test|release) ;; *) echo "channel must be test or release" >&2; exit 1 ;; esac
D="$FILES/etc/knots/release-keys"
mkdir -p "$D"
find "$D" -maxdepth 1 -type f ! -name README -delete
n=0
for dir in "$KEYS/release" $( [ "$CH" = test ] && echo "$KEYS/test" ); do
	for k in "$dir"/*; do
		[ -f "$k" ] || continue
		b=$(basename "$k")
		echo "$b" | grep -qE '^[0-9a-f]{16}$' || { echo "bad key file name: $k" >&2; exit 1; }
		head -1 "$k" | grep -q '^untrusted comment: ' || { echo "not a usign public key: $k" >&2; exit 1; }
		cp "$k" "$D/$b"; chmod 644 "$D/$b"; n=$((n + 1))
	done
done
[ -n "$(ls "$KEYS/release" 2>/dev/null)" ] || { echo "no release keys in $KEYS/release" >&2; exit 1; }
echo "$CH" >"$FILES/etc/knots/build_channel"
echo "release keys staged ($CH): $n key(s) → $D"
