#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-PROVISION — factory/provision-secret.sh (review P1 / D1) against a fake
# router: stub ssh runs the remote command locally with fw_printenv/fw_setenv
# backed by a file. Checks derivation, format (= firmware knots_secret_valid),
# determinism, refusal to overwrite a different secret, idempotency, key-file
# hygiene and label CSV privacy. Never uses a real factory key.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
P="$ROOT/factory/provision-secret.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat >"$W/bin/ssh" <<'EOF2'
#!/bin/sh
# fake router: drop options + host, run the command locally
while [ $# -gt 1 ]; do case "$1" in -*) shift ;; *) shift; break ;; esac; done
exec sh -c "$*"
EOF2
cat >"$W/bin/fw_printenv" <<'EOF2'
#!/bin/sh
[ "$1" = -n ] || exit 1
v=$(sed -n "s/^$2=//p" "$FAKE_ENV" 2>/dev/null | tail -1)
[ -n "$v" ] || { echo "## Error: \"$2\" not defined" >&2; exit 1; }
echo "$v"
EOF2
cat >"$W/bin/fw_setenv" <<'EOF2'
#!/bin/sh
grep -v "^$1=" "$FAKE_ENV" >"$FAKE_ENV.t" 2>/dev/null || true
echo "$1=$2" >>"$FAKE_ENV.t"; mv "$FAKE_ENV.t" "$FAKE_ENV"
EOF2
chmod +x "$W/bin/"*
export FAKE_ENV="$W/env" KNOTS_LABELS_CSV="$W/labels.csv" ROUTER_SSH=root@fake
echo "ethaddr=F6:78:F9:EE:82:A2" >"$FAKE_ENV"
head -c 32 /dev/urandom >"$W/key"; chmod 600 "$W/key"
head -c 32 /dev/urandom >"$W/key2"; chmod 600 "$W/key2"

prov() { PATH="$W/bin:$PATH" KNOTS_FACTORY_KEY_FILE=$1 sh "$P" --no-apply "$@" 2>&1; }
pv() { k=$1; shift; PATH="$W/bin:$PATH" KNOTS_FACTORY_KEY_FILE=$k bash "$P" --no-apply "$@" 2>&1; }

out=$(pv "$W/key") || { echo "$out" >&2; fail "first provision"; }
s1=$(sed -n 's/^knots_secret=//p' "$FAKE_ENV")
# same check the firmware uses
. /dev/stdin <<EOF2
$(awk '/^knots_secret_valid\(\)/,/^}/' "$ROOT/files/usr/libexec/knots/setup-lib.sh")
EOF2
knots_secret_valid "$s1" || fail "derived secret '$s1' fails the firmware's knots_secret_valid"
echo "$out" | grep -q "Password   : $s1" || fail "label must show the secret"
echo "$out" | grep -q "f6:78:f9:ee:82:a2" || fail "label must show the (lower-case) MAC"
pass "derived secret matches firmware format; label printed"

# independent derivation (python, same spec) — guards the encoding
exp=$(python3 -I - "$W/key" <<'PY'
import hashlib,hmac,sys
n=int.from_bytes(hmac.new(open(sys.argv[1],'rb').read(),b"f6:78:f9:ee:82:a2",hashlib.sha256).digest(),"big")
a="abcdefghjkmnpqrstuvwxyz23456789";c=[]
for _ in range(12): n,r=divmod(n,31); c.append(a[r])
s="".join(c); print(s[:4]+"-"+s[4:8]+"-"+s[8:])
PY
)
[ "$s1" = "$exp" ] || fail "derivation mismatch: $s1 vs $exp"
out=$(pv "$W/key") || { echo "$out"; fail "re-run with same key must be idempotent"; }
[ "$(sed -n 's/^knots_secret=//p' "$FAKE_ENV")" = "$s1" ] || fail "idempotent re-run changed the secret"
pass "HMAC-SHA256(key, ethaddr) spec; deterministic; idempotent"

out=$(pv "$W/key2") && fail "different key must not overwrite an existing secret without --force"
echo "$out" | grep -q "DIFFERENT knots_secret" || fail "expected label-mismatch refusal"
out=$(pv "$W/key2" --force) || { echo "$out"; fail "--force relabel"; }
s2=$(sed -n 's/^knots_secret=//p' "$FAKE_ENV")
[ "$s2" != "$s1" ] || fail "different key must give a different secret"
pass "refuses to overwrite a different secret unless --force"

chmod 644 "$W/key"
out=$(pv "$W/key") && fail "key with mode 644 must be refused"
echo "$out" | grep -q "must be 600 or 400" || fail "expected key-mode refusal"
chmod 600 "$W/key"
head -c 16 /dev/urandom >"$W/short"; chmod 600 "$W/short"
pv "$W/short" >/dev/null && fail "key shorter than 32 bytes must be refused"
out=$(PATH="$W/bin:$PATH" KNOTS_FACTORY_KEY_FILE= bash "$P" 2>&1) && fail "missing key must be refused"
keyhex=$(od -An -tx1 "$W/key" | tr -d ' \n' | cut -c1-16)
grep -rq "$keyhex" "$W/labels.csv" && fail "key material leaked into labels.csv"
[ "$(stat -c %a "$W/labels.csv")" = 600 ] || fail "labels.csv must be mode 600"
head -1 "$W/labels.csv" | grep -q '^provisioned_utc,ethaddr' || fail "labels.csv header"
pass "key file hygiene (mode, length, required); labels.csv private, no key material"

echo "foo=bar" >"$FAKE_ENV"
out=$(pv "$W/key") && fail "missing ethaddr must fail"
echo "$out" | grep -q "could not read a valid ethaddr" || fail "missing ethaddr must give a clear message (not a silent exit): $out"
pass "unreadable ethaddr → explicit error, nothing written"

git -C "$ROOT" check-ignore -q factory/labels.csv || fail "factory/labels*.csv must be gitignored"
echo "ALL PASS: test-provision-secret (T-PROVISION)"
