#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T3 / S7 / U8 / D4 — assert on-device M.2 wipe tools and UI are absent.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FAIL=0

assert_absent() {
	local p="$1"
	if [ -e "$ROOT/$p" ]; then
		echo "FAIL: wipe surface still present: $p"
		FAIL=1
	else
		echo "PASS absent $p"
	fi
}

assert_absent "files/usr/libexec/knots/storage-wipe.sh"
assert_absent "files/www/knots/storage.html"
assert_absent "files/www/knots/storage.js"
assert_absent "files/usr/libexec/knots/storage-api.sh"
assert_absent "files/usr/libexec/knots/wallet-cgi/api/storage"

# CLI must refuse wipe
KS="$ROOT/files/usr/sbin/knots-storage"
chmod +x "$KS"
if "$KS" wipe --reformat --confirm YES 2>/tmp/ks-wipe.err; then
	echo "FAIL: knots-storage wipe should refuse"; FAIL=1
else
	grep -qiE 'refusing|retired|S7' /tmp/ks-wipe.err || {
		echo "FAIL: expected refuse message"; cat /tmp/ks-wipe.err; FAIL=1
	}
	echo "PASS knots-storage wipe refused"
fi

# nginx must not proxy wipe API
if grep -q 'location /api/storage' "$ROOT/files/etc/nginx/conf.d/knots-ui.conf"; then
	echo "FAIL: /api/storage still in nginx"; FAIL=1
else
	echo "PASS no /api/storage in nginx"
fi

# REQUIREMENTS must document retirement
grep -q 'No on-device M.2 wipe' "$ROOT/REQUIREMENTS.md" || {
	echo "FAIL: REQUIREMENTS S7 text missing"; FAIL=1
}
grep -q 'S8.*Retired\|Retired.*wipe mode B' "$ROOT/REQUIREMENTS.md" || {
	echo "FAIL: S8 retired note missing"; FAIL=1
}

# Nav must not offer Storage
! grep -q 'label: "Storage"' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: Storage still in primary nav"; FAIL=1
}
grep -q 'U8' "$ROOT/files/www/knots/shell.js" || {
	echo "FAIL: U8 marker missing in shell.js"; FAIL=1
}
echo "PASS nav has no Storage wipe"

[ "$FAIL" -eq 0 ] || exit 1
echo "All no-wipe / T3 absence tests passed"
