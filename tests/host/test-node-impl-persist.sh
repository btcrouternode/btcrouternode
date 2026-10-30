#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-NODE-IMPL-PERSIST — dual persist + no overlay poison
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/files/usr/libexec/knots/node-impl-lib.sh"
# X1: the tracked source, not the gitignored staged copy (fresh clone).
SVC="$ROOT/lxc/knots-service"
NI="$ROOT/files/usr/libexec/knots/node-impl.sh"

grep -q 'STATE_SYS=/etc/knots/node-impl' "$LIB"
grep -q 'STATE_M2=/mnt/bitcoin/.node-impl' "$LIB"
grep -q 'm2_mounted' "$LIB"
grep -q 'reconcile_impl' "$LIB"
grep -q 'write_impl' "$LIB"
grep -q 'node-impl-lib.sh' "$NI"
grep -q 'write_impl' "$NI"
grep -q 'reconcile' "$NI"
grep -q 'refusing start' "$SVC" || grep -q 'not mounted' "$SVC"
grep -q 'm2_mounted' "$SVC"
grep -q 'node-impl.sh reconcile' "$ROOT/files/usr/libexec/knots/knots-start.sh"
grep -q 'BUILD_NUM' "$ROOT/build/version.env"
grep -q 'BUILD_NUM' "$ROOT/Makefile"
grep -q '{openwrt}.{knots}.{build}' "$ROOT/REQUIREMENTS.md"
grep -q 'build_number' "$ROOT/files/usr/libexec/knots/status-api.sh"
# X1: build_number is generated (gitignored) — check the build writes it.
grep -q 'etc/knots/build_number' "$ROOT/Makefile"
echo "PASS T-NODE-IMPL-PERSIST"
