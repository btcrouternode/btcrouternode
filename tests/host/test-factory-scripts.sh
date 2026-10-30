#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-FAC-1 — factory capture/flash confirm gates
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CAP="$ROOT/factory/capture-m2.sh"
FL="$ROOT/factory/flash-m2.sh"
chmod +x "$CAP" "$FL"

if "$FL" --mode datadir --image /nonexistent --device /dev/null 2>/tmp/ff.err; then
	echo "FAIL: flash should require confirm"; exit 1
fi
grep -qi 'FLASH_M2\|confirm' /tmp/ff.err || { echo "FAIL: confirm msg"; cat /tmp/ff.err; exit 1; }

# capture missing out
if "$CAP" --mode datadir --src /tmp 2>/tmp/fc.err; then
	echo "FAIL: capture should need --out"; exit 1
fi

echo "PASS T-FAC-1"
