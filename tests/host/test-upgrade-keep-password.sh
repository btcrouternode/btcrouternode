#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-UPG-PW — keep-config upgrade must not re-run factory password uci-defaults
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
U92="$ROOT/files/etc/uci-defaults/92-knots-password"

[ -f "$U92" ] || { echo "FAIL: missing 92-knots-password"; exit 1; }

grep -q 'setup-complete' "$U92" || {
	echo "FAIL: 92-knots-password must skip when setup-complete exists"; exit 1
}
grep -q 'setup-password-done' "$U92" || {
	echo "FAIL: 92-knots-password must skip when setup-password-done exists"; exit 1
}
grep -q '/etc/shadow' "$U92" || {
	echo "FAIL: 92-knots-password must skip when shadow already has a hash"; exit 1
}
grep -q 'first boot only\|first boot ONLY' "$U92" || {
	echo "FAIL: 92-knots-password must document first-boot-only intent"; exit 1
}

grep -q 'keep.d/knots' "$ROOT/files/lib/upgrade/keep.d/knots" || {
	echo "FAIL: keep.d/knots missing"; exit 1
}
grep -q 'uci-defaults whiteouts' "$ROOT/files/lib/upgrade/keep.d/knots" || {
	echo "FAIL: keep.d/knots must document uci-defaults whiteout gap"; exit 1
}

APPLY="$ROOT/files/usr/libexec/knots/upgrade-apply.sh"
grep -q 'sysupgrade -v' "$APPLY" || {
	echo "FAIL: keep_config=1 must use sysupgrade -v only"; exit 1
}
grep -q 'sysupgrade -n -v' "$APPLY" || {
	echo "FAIL: keep_config=0 must use sysupgrade -n -v"; exit 1
}
grep -q 'upgrade-apply.sh' "$ROOT/files/usr/libexec/knots/settings-api.sh" || {
	echo "FAIL: settings-api must spawn upgrade-apply.sh"; exit 1
}

echo "PASS T-UPG-PW"
