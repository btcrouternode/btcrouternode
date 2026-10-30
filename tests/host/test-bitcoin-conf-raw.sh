#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-CONF-RAW — review S4 / B9 (2026-10-10): Settings advanced bitcoin.conf editor.
#  - an unchanged save of the shipped baseline is accepted (it has TWO bind=
#    lines; the old first-value compare refused every save with blocked_key:bind)
#  - protected keys cannot be added/removed/changed, incl. spacing, section
#    prefix, leading "-", no-negation, includeconf and *notify hooks
#  - GET conf shows rpcauth/rpcpassword as <hidden>; saving the redacted text
#    restores the real values
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/files/usr/libexec/knots/bitcoin-conf-lib.sh"
BASE="$ROOT/lxc/bitcoin.conf"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
SECRET='knotsrpc:0123456789abcdef0123456789abcdef$aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
{ cat "$BASE"; printf '\n# BEGIN knots-external-rpc\nrpcauth=%s\n# END knots-external-rpc\n' "$SECRET"; } >"$W/cur.conf"

lib() { # run a snippet with the lib loaded against $W/cur.conf
	sh -c ". '$LIB'; CONF_HOST='$W/cur.conf'; CONF_BAK='$W/cur.bak'; $1"
}
blocked() { # FILE → key or ""
	lib "conf_raw_has_blocked '$1' || true"
}

cp "$W/cur.conf" "$W/same.conf"
[ -z "$(blocked "$W/same.conf")" ] || fail "unchanged baseline refused: $(blocked "$W/same.conf")"
sed 's/^dbcache=1024/dbcache=512/; s/^# cookie auth.*/# edited comment/' "$W/cur.conf" >"$W/ok.conf"
[ -z "$(blocked "$W/ok.conf")" ] || fail "safe edit refused: $(blocked "$W/ok.conf")"
awk '/^bind=/{b[++n]=$0; next} {print} END{print b[2]; print b[1]}' "$W/cur.conf" >"$W/reorder.conf"
[ -z "$(blocked "$W/reorder.conf")" ] || fail "reordering protected lines refused"
pass "unchanged / safe edits / reordering accepted (two bind= lines)"

try() { # NAME EXPECTED-KEY SED-or-APPEND
	name=$1 want=$2 edit=$3
	case "$edit" in
		+*) { cat "$W/cur.conf"; printf '%s\n' "${edit#+}"; } >"$W/t.conf" ;;
		*) sed "$edit" "$W/cur.conf" >"$W/t.conf" ;;
	esac
	got=$(blocked "$W/t.conf")
	[ "$got" = "$want" ] || fail "$name: got '$got' want '$want'"
}
try "spaces round =" rpcallowip '+rpcallowip = 0.0.0.0/0'
try "section prefix" rpcallowip '+main.rpcallowip=0.0.0.0/0'
try "leading dash" rpcallowip '+-rpcallowip=0.0.0.0/0'
try "upper case" rpcallowip '+RPCALLOWIP=0.0.0.0/0'
try "includeconf" includeconf '+includeconf=/tmp/evil.conf'
try "blocknotify" blocknotify '+blocknotify=/bin/sh -c id'
try "startupnotify" startupnotify '+startupnotify=touch /tmp/x'
try "nolisten" listen '+nolisten=1'
try "remove 2nd bind" bind '/^bind=\[fd21/d'
try "change rpcbind" rpcbind 's/^rpcbind=.*/rpcbind=0.0.0.0/'
try "remove rpcauth" rpcauth '/^rpcauth=/d'
try "trailing comment trick" rpcallowip 's|^rpcallowip=21.21.21.0/24|rpcallowip=0.0.0.0/0 # 21.21.21.0/24|'
pass "protected keys: spacing/prefix/dash/case/no-/includeconf/notify/removal all refused"

lib "conf_redact '$W/cur.conf'" >"$W/red.conf"
grep -q '^rpcauth=<hidden>$' "$W/red.conf" || fail "rpcauth not redacted"
grep -q 'aaaaaaaa' "$W/red.conf" && fail "rpcauth secret leaked by conf_redact"
lib "conf_unredact '$W/red.conf'" >"$W/unred.conf"
cmp -s "$W/unred.conf" "$W/cur.conf" || fail "unredact(redact(conf)) != conf"
pass "GET conf redacts rpcauth; unredact restores it exactly"

cp "$W/cur.conf" "$W/orig.conf"
sed 's/^dbcache=1024/dbcache=768/' "$W/red.conf" >"$W/save.conf"
lib "conf_write_raw_validated '$W/save.conf'" || fail "saving redacted text refused"
grep -q '^dbcache=768$' "$W/cur.conf" || fail "edit not written"
grep -qF "rpcauth=$SECRET" "$W/cur.conf" || fail "rpcauth lost after saving redacted text"
grep -q '<hidden>' "$W/cur.conf" && fail "<hidden> written into bitcoin.conf"
pass "save of redacted text keeps the real rpcauth and applies the edit"

# Form path (Settings safe knobs) — regression: 7e7e349 deleted
# conf_apply_safe_pairs and every normal Settings save failed (write_failed).
cp "$W/orig.conf" "$W/cur.conf"
printf 'dbcache=900\nmaxconnections=50\n' | lib "conf_apply_safe_pairs" || fail "conf_apply_safe_pairs failed"
grep -q '^dbcache=900$' "$W/cur.conf" || fail "safe pair dbcache not applied"
grep -q '^maxconnections=50$' "$W/cur.conf" || fail "safe pair maxconnections not applied"
[ "$(grep -c '^dbcache=' "$W/cur.conf")" = 1 ] || fail "dbcache duplicated"
grep -qF "rpcauth=$SECRET" "$W/cur.conf" || fail "external-rpc block lost by safe save"
lib "conf_assert_product_keys" || fail "product keys lost by safe save"
pass "Settings form save applies safe knobs and keeps the external-rpc block"

echo "ALL PASS: test-bitcoin-conf-raw (T-CONF-RAW)"
