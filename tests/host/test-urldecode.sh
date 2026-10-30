#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# CGI urldecode must stay O(n). Per-character `cut` made Wi-Fi IUE save time out
# before uci commit (R7/U17).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/files/usr/libexec/knots/cgi-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -f "$LIB" ] || fail "missing cgi-lib.sh"
fn=$(awk '/^urldecode\(\)/,/^}$/' "$LIB")
[ -n "$fn" ] || fail "urldecode() missing"
printf '%s\n' "$fn" | grep -q 'cut -c' && fail "urldecode must not use per-character cut"
printf '%s\n' "$fn" | grep -q awk || fail "urldecode must be O(n) awk"

# Host-run the same function the CGI sources.
# shellcheck disable=SC3043,SC2094
eval "$fn"

eq() {
	got=$(urldecode "$1")
	[ "$got" = "$2" ] || fail "urldecode '$1' → '$got' want '$2'"
}

eq 'Australia%2FSydney' 'Australia/Sydney'
eq 'hello+world' 'hello world'
eq 'a%20b' 'a b'
eq 'ab%2Fcd%25ef' 'ab/cd%ef'
eq 'rnode' 'rnode'
eq '' ''

p='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789a'
[ ${#p} -eq 63 ] || fail "fixture length"
start=$(date +%s)
got=$(urldecode "$p")
end=$(date +%s)
[ "$got" = "$p" ] || fail "63-char passphrase round-trip"
[ $((end - start)) -le 2 ] || fail "urldecode 63-char took $((end - start))s"

echo "PASS: urldecode O(n) + form-encoded fields"
