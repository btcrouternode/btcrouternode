#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Generate the RNode RELEASE signing key (usign / ed25519). Run on the OFFLINE
# factory/signing machine — like the factory key, the SECRET key must never be
# copied to a build machine that is online, into this repository, or into
# firmware. Only the public key is committed (files/etc/knots/release-keys/).
#
# Usage: factory/release-keygen.sh OUTDIR [LABEL [PUBDIR]]
#   LABEL (e.g. A or B) names the files rnode-release-LABEL.{sec,pub}; two keys
#   (A signs, B is the standby) are both installed in firmware (P3-D16).
#   PUBDIR, if given, also receives a copy of the PUBLIC key (the tools stick).
# Needs: usign (OpenWrt Image Builder: staging_dir/host/bin/usign, the copy
# next to this script on the offline key USB — factory/make-keygen-usb.sh — or USIGN=)
set -eu
OUT="${1:?usage: release-keygen.sh OUTDIR [LABEL [PUBDIR]]}"
LABEL="${2:-}"
PUBDIR="${3:-}"
case "$LABEL" in ''|[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9_-]*) ;; *) echo "bad LABEL" >&2; exit 1 ;; esac
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
if [ -z "${USIGN:-}" ] && [ -x "$HERE/usign/bin/usign" ]; then
	USIGN="$HERE/usign/bin/usign"
fi
USIGN="${USIGN:-$ROOT/build/imagebuilder/staging_dir/host/bin/usign}"
NAME=rnode-release${LABEL:+-$LABEL}
command -v "$USIGN" >/dev/null 2>&1 || [ -x "$USIGN" ] || { echo "usign not found (set USIGN=)" >&2; exit 1; }
[ ! -e "$OUT/$NAME.sec" ] || { echo "refusing: $OUT/$NAME.sec already exists" >&2; exit 1; }
mkdir -p "$OUT"
umask 077
"$USIGN" -G -s "$OUT/$NAME.sec" -p "$OUT/$NAME.pub" -c "RNode release key${LABEL:+ $LABEL} $(date -u +%Y-%m-%d)"
fp=$("$USIGN" -F -p "$OUT/$NAME.pub")
cp "$OUT/$NAME.pub" "$OUT/$fp"
chmod 600 "$OUT/$NAME.sec"
# Prove the pair works before anyone relies on it: sign and verify a test file.
t=$(mktemp -d)
echo "RNode key self-test $fp" >"$t/msg"
"$USIGN" -S -m "$t/msg" -s "$OUT/$NAME.sec" -x "$t/msg.sig"
"$USIGN" -V -q -m "$t/msg" -p "$OUT/$NAME.pub" -x "$t/msg.sig" || { rm -rf "$t"; echo "SELF-TEST FAILED" >&2; exit 1; }
rm -rf "$t"
if [ -n "$PUBDIR" ]; then
	mkdir -p "$PUBDIR"
	cp "$OUT/$NAME.pub" "$PUBDIR/$fp"
	chmod 644 "$PUBDIR/$fp" 2>/dev/null || true
fi
cat <<MSG
Release key${LABEL:+ $LABEL} created (sign + verify self-test passed).
  SECRET (keep offline, never copy it anywhere else): $OUT/$NAME.sec
  PUBLIC fingerprint: $fp
Commit ONLY the public key, as files/etc/knots/release-keys/$fp :
  $OUT/$fp${PUBDIR:+
  (copied to $PUBDIR/$fp)}
From the first build that contains it, Settings refuses unsigned upgrades.
MSG
