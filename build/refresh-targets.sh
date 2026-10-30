#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Replace the build output (OUT/targets) with a fresh Image Builder copy, but
# never touch the signed releases kept in OUT/targets/mediatek/filogic/Releases
# (owner decision 2026-10-22: releases live next to the builds).
# Usage: refresh-targets.sh IB_TARGETS_DIR OUT_DIR
set -eu
SRC="${1:?usage: refresh-targets.sh IB_TARGETS_DIR OUT_DIR}"
OUT="${2:?usage: refresh-targets.sh IB_TARGETS_DIR OUT_DIR}"
T="$OUT/targets"
REL="$T/mediatek/filogic/Releases"
[ -d "$SRC" ] || { echo "no Image Builder output at $SRC" >&2; exit 1; }
mkdir -p "$T"
find "$T" -depth -mindepth 1 \
	! -path "$REL" ! -path "$REL/*" \
	! -path "$T/mediatek" ! -path "$T/mediatek/filogic" -exec rm -rf {} +
cp -a "$SRC/." "$T/"
