#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Stage the offline folder rnode-sign/ for factory/offline/rnode-offline.sh
# (owner, 2026-10-27: one script in the live session, nothing to type).
#
#   build/stage-offline.sh keys|sign|identity [STATION]     (make offline-stage MODE=… STATION=…)
#     keys     — the tools + the script, to make new release keys A and B
#     sign     — also the current RELEASE=1 build in unsigned/, to sign with key A
#     identity — a maintainer's PGP identity + firmware key: needs
#                MAINTAINER_NAME, MAINTAINER_EMAIL, FIRMWARE_LABEL in the environment
# Writes bin/offline-stage/rnode-sign/ and, with STATION=user@host, copies it to
# STATION:rnode-sign/ (keeping new-public/ there). EXPECTED records what this
# build PC saw: the tools and release fingerprints and the keys built in.
set -eu
MODE="${1:?usage: stage-offline.sh keys|sign [STATION]}"
STATION="${2:-}"
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$MODE" in keys|sign|identity) ;; *) echo "mode must be keys, sign or identity" >&2; exit 2 ;; esac
if [ "$MODE" = identity ]; then
	[ -n "${MAINTAINER_NAME:-}" ] && [ -n "${MAINTAINER_EMAIL:-}" ] && [ -n "${FIRMWARE_LABEL:-}" ] \
		|| { echo "identity needs MAINTAINER_NAME, MAINTAINER_EMAIL and FIRMWARE_LABEL" >&2; exit 2; }
	case "$FIRMWARE_LABEL" in *[!A-Za-z0-9]*|"") echo "FIRMWARE_LABEL: letters and digits only" >&2; exit 2 ;; esac
fi
TOOLS="$ROOT/bin/offline-tools/rnode-keygen"
[ -f "$TOOLS/SHA256SUMS" ] || { echo "no offline tools — run: make offline-tools" >&2; exit 1; }
OV=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env")
KV=$(sed -n 's/^CORE_VER := //p' "$ROOT/build/version.env")
BN=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env")
REL="bpi-r4-phase2-$OV.$KV.$BN-squashfs-sysupgrade.itb"
IMG="$ROOT/bin/targets/mediatek/filogic/$REL"
OUT="$ROOT/bin/offline-stage/rnode-sign"
rm -rf "$OUT"; mkdir -p "$OUT/unsigned" "$OUT/signed" "$OUT/release-keys"
cp -r "$TOOLS" "$OUT/rnode-keygen"
# Owner 2026-10-31: in the live session, browse to this folder, cd into it,
# sudo bash sign.sh — it asks for everything else.
cp "$ROOT/factory/offline/sign.sh" "$OUT/"; chmod 755 "$OUT/sign.sh"
[ -f "$TOOLS/rnode-offline.sh" ] || { echo "offline tools are older than rnode-offline.sh — run: make offline-tools" >&2; exit 1; }
cmp -s "$TOOLS/rnode-offline.sh" "$ROOT/factory/offline/rnode-offline.sh" || { echo "offline tools out of date — run: make offline-tools" >&2; exit 1; }
tools_sha=$(cd "$OUT/rnode-keygen" && sha256sum SHA256SUMS | cut -d' ' -f1)
rel_sha=""; keys=""
if [ "$MODE" = sign ]; then
	[ "$(cat "$ROOT/files/etc/knots/build_channel" 2>/dev/null)" = release ] \
		|| { echo "the current build is not a release build (make image RELEASE=1)" >&2; exit 1; }
	[ -f "$IMG" ] || { echo "no build $IMG" >&2; exit 1; }
	cp "$IMG" "$OUT/unsigned/"
	rel_sha=$(sha256sum "$IMG" | cut -d' ' -f1)
	# the public keys BUILT INTO this release (what routers will trust)
	for k in "$ROOT"/files/etc/knots/release-keys/*; do
		b=$(basename "$k"); echo "$b" | grep -qE '^[0-9a-f]{16}$' || continue
		cp "$k" "$OUT/release-keys/$b"; keys="$keys $b"
	done
	[ -n "$keys" ] || { echo "no release keys staged in the build" >&2; exit 1; }
fi
cat >"$OUT/EXPECTED" <<EOF
# staged by the build PC $(date -u +%Y-%m-%dT%H:%M:%SZ) — mode $MODE
TOOLS_SHA256=$tools_sha
RELEASE=$REL
RELEASE_SHA256=$rel_sha
RELEASE_KEYS="${keys# }"
MAINTAINER_NAME="${MAINTAINER_NAME:-}"
MAINTAINER_EMAIL="${MAINTAINER_EMAIL:-}"
FIRMWARE_LABEL="${FIRMWARE_LABEL:-}"
EOF
echo "Staged $OUT ($MODE)"
echo "  tools SHA256:   $tools_sha"
[ -z "$rel_sha" ] || { echo "  release:        $REL"; echo "  release SHA256: $rel_sha"; echo "  keys built in:  ${keys# }"; }
if [ -n "$STATION" ]; then
	rsync -a --delete --exclude new-public/ --exclude "new-public.*/" --exclude new/ --exclude "dead-*/" --exclude identity/ "$OUT/" "$STATION:rnode-sign/"
	echo "Copied to $STATION:rnode-sign/"
	echo "Live session: browse to rnode-sign on the laptop's drive, cd into it, sudo bash sign.sh"
fi
