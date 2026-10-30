#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-INPUT — review S7 / B10 / N15 / N17 (2026-10-10).
#  - Wi-Fi key: 8-63 printable ASCII only (no %0A config injection)
#  - SSID: 1-32 BYTES, UTF-8 ok, no control bytes
#  - root password: no control bytes (newline = extra chpasswd line)
#  - json_escape: newline/CR/tab escaped, other control bytes dropped, \ and "
#    escaped — output parses as JSON (run under busybox too when available)
#  - setup_schedule_cutover passes values to sh -c as arguments
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/files/usr/libexec/knots/setup-lib.sh"
RPC="$ROOT/files/usr/libexec/knots/rpc.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

FN=$(mktemp -d)
trap 'rm -rf "$FN"' EXIT
awk '/^setup_has_ctl\(\)/,/^}/; /^setup_is_printable_ascii\(\)/,/^}/; /^setup_byte_len\(\)/,/^}/; /^setup_wifi_validate\(\)/,/^}/' \
	"$LIB" >"$FN/lib.sh"
echo 'FACTORY_WIFI_COUNTRY=AU' >>"$FN/lib.sh"
awk '/^json_escape\(\)/,/^}/' "$RPC" >>"$FN/lib.sh"

NL='
'
TAB=$(printf '\t')
v() { sh -c ". '$FN/lib.sh'; setup_wifi_validate \"\$1\" \"\$2\" AU && echo Y || echo N" _ "$1" "$2"; }

[ "$(v rnode goodpass1)" = Y ] || fail "plain SSID/key"
[ "$(v 'Café Ünïcode' goodpass1)" = Y ] || fail "UTF-8 SSID must be allowed"
[ "$(v rnode 'pass with spaces!~')" = Y ] || fail "printable ASCII key with spaces"
[ "$(v rnode "goodpass1${NL}ssid=evil")" = N ] || fail "newline in key must be refused"
[ "$(v rnode "goodpass1${TAB}x")" = N ] || fail "tab in key must be refused"
[ "$(v rnode 'pässwörd123')" = N ] || fail "non-ASCII key must be refused (WPA2 passphrase is ASCII)"
[ "$(v "rnode${NL}x" goodpass1)" = N ] || fail "newline in SSID must be refused"
[ "$(v 'ééééééééééééééééé' goodpass1)" = N ] || fail "SSID over 32 bytes (17 x 2-byte chars) must be refused"
[ "$(v '0123456789012345678901234567890' goodpass1)" = Y ] || fail "31-byte SSID"
pass "Wi-Fi SSID/key byte-level validation"

awk '/^setup_set_root_password\(\)/,/^}/' "$LIB" | grep -q 'setup_has_ctl "\$pass"' \
	|| fail "setup_set_root_password must refuse control bytes"
[ "$(sh -c ". '$FN/lib.sh'; setup_has_ctl \"\$1\" && echo Y || echo N" _ "abcdefgh${NL}root2:x")" = Y ] \
	|| fail "setup_has_ctl must see a newline"
pass "root password refuses control bytes"

check_json() {
	shell=$1
	out=$($shell -c ". '$FN/lib.sh'; json_escape \"\$1\"" _ "$(printf 'a\\b"c\td\re\001f\nline2')")
	printf '{"v":"%s"}' "$out" | python3 -I -c '
import json, sys
v = json.load(sys.stdin)["v"]
assert v == "a\\b\"c\td\ref\nline2", repr(v)
' || fail "json_escape under $shell: $out"
}
check_json sh
BBBIN=$(command -v busybox 2>/dev/null || true)
case "$BBBIN" in /*) ;; *) BBBIN= ;; esac
if [ -n "$BBBIN" ]; then
	BB=$(mktemp -d)
	for t in sh awk sed tr; do ln -s "$BBBIN" "$BB/$t"; done
	PATH="$BB:$PATH" check_json "$BB/sh"
	rm -rf "$BB"
	pass "json_escape produces valid JSON (system sh + busybox)"
else
	pass "json_escape produces valid JSON (busybox not installed — system sh only)"
fi

awk '/^setup_schedule_cutover\(\)/,/^}/' "$LIB" | grep -q "knots-cutover \"\$old_ip\"" \
	|| fail "setup_schedule_cutover must pass values as sh -c arguments"
awk '/^setup_schedule_cutover\(\)/,/^}/' "$LIB" | grep -q "'\$old_ip'" \
	&& fail "setup_schedule_cutover still splices \$old_ip into script text"
pass "cutover values passed as arguments, not spliced"

echo "ALL PASS: test-input-validation (T-INPUT)"
