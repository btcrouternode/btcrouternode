#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Prepare the offline tools for release-key generation and signing (P3-D16).
# Run on the build PC; `make offline-tools` writes them into the project folder
# (bin/offline-tools/rnode-keygen) — nothing is kept on USB media.
# It gets a self-contained x86_64 usign (Image Builder's binary + its own loader
# and libc, so it runs on any 64-bit Linux live USB), release-keygen.sh, the
# instructions and SHA256SUMS; also fwtool + sign-image.sh to sign releases
# offline with key A. No secret ever goes on this stick: the secret keys
# are written straight onto the encrypted key sticks A and B.
#
# Usage: factory/make-keygen-usb.sh DEST
set -eu
DEST="${1:?usage: make-keygen-usb.sh DEST}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
H="${HOST_DIR:-$ROOT/build/imagebuilder/staging_dir/host}"
[ -d "$DEST" ] || { echo "no such directory: $DEST" >&2; exit 1; }
for f in bin/usign bin/.usign.bin bin/fwtool bin/.fwtool.bin lib/ld-linux-x86-64.so.2 lib/libc.so.6 lib/runas.so; do
	[ -f "$H/$f" ] || { echo "missing $H/$f (make imagebuilder first)" >&2; exit 1; }
done
K="$DEST/rnode-keygen"
mkdir -p "$K/usign/bin" "$K/usign/lib" "$K/public"
cp "$H/bin/usign" "$H/bin/.usign.bin" "$H/bin/fwtool" "$H/bin/.fwtool.bin" "$K/usign/bin/"
cp "$H/lib/ld-linux-x86-64.so.2" "$H/lib/libc.so.6" "$H/lib/runas.so" "$K/usign/lib/"
chmod 755 "$K/usign/bin/usign" "$K/usign/bin/.usign.bin" "$K/usign/bin/fwtool" "$K/usign/bin/.fwtool.bin" "$K/usign/lib/ld-linux-x86-64.so.2"
cp "$ROOT/factory/release-keygen.sh" "$ROOT/factory/sign-image.sh" "$ROOT/factory/offline/rnode-offline.sh" "$ROOT/factory/offline/sign-release.sh" "$K/"
chmod 755 "$K/release-keygen.sh" "$K/sign-image.sh" "$K/rnode-offline.sh" "$K/sign-release.sh"
cp "$ROOT/factory/OFFLINE-KEYGEN.md" "$K/README.md"
( cd "$K" && find . -type f ! -name SHA256SUMS ! -path './public/*' | sort | xargs sha256sum >SHA256SUMS )
# Prove the copy works the way the guide uses it: copied off the stick (FAT
# sticks are often mounted noexec), exec bits set, a throwaway key, deleted.
t=$(mktemp -d)
cp -r "$K" "$t/" && ( cd "$t/rnode-keygen" && sha256sum -c --quiet SHA256SUMS ) \
	|| { rm -rf "$t"; echo "tool set copy does not verify" >&2; exit 1; }
( cd "$t/rnode-keygen" && chmod +x *.sh usign/bin/* usign/bin/.*.bin usign/lib/ld-linux-x86-64.so.2 )
"$t/rnode-keygen/usign/bin/usign" -G -s "$t/x.sec" -p "$t/x.pub" -c selftest
"$t/rnode-keygen/usign/bin/usign" -F -p "$t/x.pub" >/dev/null
rm -rf "$t"
sync
echo "Offline tools ready: $K"
echo "SHA256 of the tool set (write it down and compare on the offline laptop):"
sha256sum "$K/SHA256SUMS"
