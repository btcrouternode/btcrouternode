#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-PRODUCT-VER (owner, 2026-11-08): the product version is
# {OpenWrt major}.{router fix #}.{Core major}.{node fix #} (e.g. 25.0.32.0),
# one source (build/version.env PRODUCT_VER, checked by build/product-version.sh),
# the same in make, scripts and the factory station; the build number is separate.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
PVS="$ROOT/build/product-version.sh"
pv=$(sh "$PVS") || fail "product-version.sh: $pv"
echo "$pv" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || fail "not four numbers: $pv"
[ "$(make -s -C "$ROOT" version 2>/dev/null | head -1)" = "$pv" ] || fail "make version disagrees with $pv"
grep -q "^BUILD_NUM := [0-9][0-9]*$" "$ROOT/build/version.env" || fail "BUILD_NUM must stay a separate number"
pass "PRODUCT_VER $pv: four numbers, make and scripts agree, build number separate"

# A version that does not match OpenWrt / Core majors is refused
sed 's/^PRODUCT_VER := .*/PRODUCT_VER := 99.0.32.0/' "$ROOT/build/version.env" >"$W/a.env"
sh "$PVS" "$W/a.env" >/dev/null 2>&1 && fail "wrong OpenWrt major accepted"
sed 's/^PRODUCT_VER := .*/PRODUCT_VER := 25.0.99.0/' "$ROOT/build/version.env" >"$W/b.env"
sh "$PVS" "$W/b.env" >/dev/null 2>&1 && fail "wrong Core major accepted"
sed 's/^PRODUCT_VER := .*/PRODUCT_VER := 25.0.32/' "$ROOT/build/version.env" >"$W/c.env"
sh "$PVS" "$W/c.env" >/dev/null 2>&1 && fail "three-part version accepted"
pass "mismatching or malformed PRODUCT_VER refused"

# Nobody assembles the version from parts any more
if grep -rnE 'OPENWRT_VER\}?\.\$\{?CORE_VER|\$OV\.\$KV|get\(.OPENWRT_VER.\)\}\.' "$ROOT/build" "$ROOT/factory" "$ROOT/tests/host" 2>/dev/null | grep -v test-product-version; then
	fail "a script still builds the version from OPENWRT_VER/CORE_VER"
fi
grep -q "get('PRODUCT_VER')" "$ROOT/factory/station/rnode_station.py" || fail "station must read PRODUCT_VER"
pass "scripts and station take the version from PRODUCT_VER"
echo "ALL PASS: test-product-version"
