#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Former T-STO-3c/d loop wipe — retired with S7. Keep target green.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
echo "SKIP test-wipe-loop: on-device M.2 wipe retired (REQUIREMENTS S7)"
# Still assert the wipe script is gone so accidental reintroduction fails CI
if [ -e "$ROOT/files/usr/libexec/knots/storage-wipe.sh" ]; then
	echo "FAIL: storage-wipe.sh must not exist"; exit 1
fi
echo "PASS wipe script absent"
exit 0
