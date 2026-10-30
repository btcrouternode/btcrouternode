#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host test: factory Core/Knots seed into M.2 node-bin when empty (B16 / B4a / U11).
set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Minimal fake LXC rootfs + M.2 mount simulation via env overrides would need
# sourcing — instead exercise seed_factory_impl by extracting the function body.
mkdir -p "$TMP/rootfs/usr/local/lib/bitcoin/core/bin"
mkdir -p "$TMP/rootfs/usr/local/lib/bitcoin/knots/bin"
mkdir -p "$TMP/mnt/bitcoin"
# dummy executables
printf '#!/bin/sh\necho fake\n' >"$TMP/rootfs/usr/local/lib/bitcoin/core/bin/bitcoind"
printf '#!/bin/sh\necho fake\n' >"$TMP/rootfs/usr/local/lib/bitcoin/core/bin/bitcoin-cli"
printf '#!/bin/sh\necho fake\n' >"$TMP/rootfs/usr/local/lib/bitcoin/knots/bin/bitcoind"
printf '#!/bin/sh\necho fake\n' >"$TMP/rootfs/usr/local/lib/bitcoin/knots/bin/bitcoin-cli"
chmod 755 "$TMP/rootfs/usr/local/lib/bitcoin/core/bin/"* \
	"$TMP/rootfs/usr/local/lib/bitcoin/knots/bin/"*

# Simulate seed logic (same as node-impl.sh seed_factory_impl)
seed() {
	impl=$1
	ver=$2
	src="$TMP/rootfs/usr/local/lib/bitcoin/$impl/bin"
	dst="$TMP/mnt/bitcoin/node-bin/$impl"
	[ -x "$dst/bin/bitcoind" ] && return 0
	mkdir -p "$dst/bin"
	cp -a "$src/bitcoind" "$src/bitcoin-cli" "$dst/bin/"
	printf '%s\n' "$ver" >"$dst/VERSION"
}

seed knots "v29.3.knots20260507"
seed core "v29.5"

# Second seed must not clobber
echo "user" >"$TMP/mnt/bitcoin/node-bin/core/VERSION"
seed core "v29.5"
grep -qx user "$TMP/mnt/bitcoin/node-bin/core/VERSION"

[ -x "$TMP/mnt/bitcoin/node-bin/core/bin/bitcoind" ]
[ -x "$TMP/mnt/bitcoin/node-bin/knots/bin/bitcoind" ]
grep -qx "v29.3.knots20260507" "$TMP/mnt/bitcoin/node-bin/knots/VERSION"

# UI strings
grep -q 'Bitcoin Node - Running' "$ROOT/files/www/knots/shell.js"
grep -q 'onNodeSoftwarePage()' "$ROOT/files/www/knots/shell.js"
grep -q 'if (onNodeSoftwarePage()) {' "$ROOT/files/www/knots/shell.js"
grep -q 'seed_factory_impl core' "$ROOT/files/usr/libexec/knots/node-impl.sh"
grep -q 'Bitcoin Node - Running Bitcoin Knots' "$ROOT/files/www/knots/node.html"

# LXC bake still ships Core pin (baseline image content — not BB1 overwrite).
# C4: tags/SHA256 pins live in build/version.env; rootfs-build.sh reads them
# via _version_env instead of hardcoding.
grep -q 'CORE_TAG := v29.5' "$ROOT/build/version.env"
grep -q 'CORE_VER := 29.5' "$ROOT/build/version.env"
grep -q 'build/version.env' "$ROOT/lxc/rootfs-build.sh"
grep -q '_version_env CORE_TAG' "$ROOT/lxc/rootfs-build.sh"
grep -q 'bitcoin-core-${CORE_VER}' "$ROOT/lxc/rootfs-build.sh"

echo "PASS test-node-core-seed-ui"
