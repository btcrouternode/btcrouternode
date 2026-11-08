#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Prints the product version PRODUCT_VER from build/version.env, after checking
# it (owner, 2026-11-08): {OpenWrt major}.{router fix #}.{Bitcoin Core major}.{node fix #},
# e.g. 25.0.32.0 for OpenWrt 25.12.6 + Core 32.1. The 1st and 3rd numbers must
# be the majors of OPENWRT_VER and CORE_VER; the 2nd and 4th are our own
# fix-release counters. The build number (BUILD_NUM) is separate. Every script
# takes the version from here.
set -eu
VE="${1:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/version.env}"
get() { sed -nE "s/^$1[[:space:]]*:=[[:space:]]*([^[:space:]#]+).*/\1/p" "$VE" | tail -n1; }
pv=$(get PRODUCT_VER); ov=$(get OPENWRT_VER); cv=$(get CORE_VER)
echo "$pv" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || { echo "product-version: PRODUCT_VER '$pv' is not N.N.N.N" >&2; exit 1; }
[ "${pv%%.*}" = "${ov%%.*}" ] || { echo "product-version: PRODUCT_VER $pv must start with the OpenWrt major (${ov%%.*})" >&2; exit 1; }
third=$(echo "$pv" | cut -d. -f3)
[ "$third" = "${cv%%.*}" ] || { echo "product-version: PRODUCT_VER $pv must have the Core major (${cv%%.*}) third" >&2; exit 1; }
echo "$pv"
