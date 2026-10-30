#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NODE-TLS — review P3 / P5 / D3 (2026-10-10): local CA + leaf.
#  P3  new CA carries critical nameConstraints (appliance names, .local, .lan,
#      private/loopback IPv4); a leaf for a public name or IP signed by that
#      CA fails verification; the shipped leaf verifies.
#  D3  an existing CA is kept on a normal run (no silent rotation); only
#      --rotate-ca / --force replaces it.
#  P5  leaf renewed when it expires within 30 days; key and cert always match.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TLS="$ROOT/files/usr/libexec/knots/node-ui-tls.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v openssl >/dev/null 2>&1 || { echo "SKIP T-NODE-TLS: no openssl"; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export KNOTS_TLS_DIR="$W/tls" KNOTS_WWW_DIR="$W/www" KNOTS_LAN_IP=192.168.1.254
run() { PATH="/usr/bin:/bin" sh "$TLS" "$@" >/dev/null 2>"$W/err" || { cat "$W/err" >&2; fail "node-ui-tls.sh $*"; }; }
fp() { openssl x509 -in "$KNOTS_TLS_DIR/ca.pem" -noout -fingerprint -sha256 | cut -d= -f2; }
pair_ok() {
	a=$(openssl x509 -in "$KNOTS_TLS_DIR/cert.pem" -noout -pubkey | openssl sha256)
	b=$(openssl pkey -in "$KNOTS_TLS_DIR/key.pem" -pubout | openssl sha256)
	[ "$a" = "$b" ]
}

run node-router
openssl x509 -in "$KNOTS_TLS_DIR/ca.pem" -noout -text >"$W/ca.txt"
grep -q 'X509v3 Name Constraints: critical' "$W/ca.txt" || fail "CA must carry critical nameConstraints"
for want in 'DNS:node-router' 'DNS:local' 'DNS:lan' 'IP:192.168.0.0/255.255.0.0' 'IP:10.0.0.0/255.0.0.0'; do
	grep -q "$want" "$W/ca.txt" || fail "nameConstraints missing $want"
done
[ "$(cat "$KNOTS_TLS_DIR/.tls-layout")" = local-ca-v2 ] || fail "layout must be local-ca-v2"
openssl verify -CAfile "$KNOTS_TLS_DIR/ca.pem" "$KNOTS_TLS_DIR/cert.pem" >/dev/null 2>&1 \
	|| fail "appliance leaf must verify under the constrained CA"
pair_ok || fail "key.pem and cert.pem must match"
[ "$(stat -c %a "$KNOTS_TLS_DIR/ca.key")" = 600 ] && [ "$(stat -c %a "$KNOTS_TLS_DIR/key.pem")" = 600 ] \
	|| fail "private keys must be mode 600"
cmp -s "$KNOTS_TLS_DIR/ca.pem" "$KNOTS_WWW_DIR/knots-ca.crt" || fail "published CA must be the CA"
pass "constrained CA (critical nameConstraints), leaf verifies, key/cert match, published"

# Constraints actually bite: a leaf for a public name / IP signed by this CA fails.
evil() { # SAN
	printf '[r]\ndistinguished_name=d\nprompt=no\n[d]\nCN=x\n[e]\nsubjectAltName=%s\n' "$1" >"$W/e.cnf"
	openssl req -nodes -newkey rsa:2048 -keyout "$W/e.key" -out "$W/e.csr" -config "$W/e.cnf" -section r 2>/dev/null \
		|| openssl req -nodes -newkey rsa:2048 -keyout "$W/e.key" -out "$W/e.csr" -config "$W/e.cnf" 2>/dev/null
	openssl x509 -req -in "$W/e.csr" -CA "$KNOTS_TLS_DIR/ca.pem" -CAkey "$KNOTS_TLS_DIR/ca.key" \
		-CAcreateserial -CAserial "$W/e.srl" -out "$W/e.pem" -days 1 -extfile "$W/e.cnf" -extensions e 2>/dev/null
	openssl verify -CAfile "$KNOTS_TLS_DIR/ca.pem" "$W/e.pem" 2>&1
}
for san in 'DNS:www.bank.example.com' 'DNS:accounts.google.com' 'IP:8.8.8.8' 'DNS:rnode.local.evil.com'; do
	out=$(evil "$san") && case "$out" in *": OK"*) fail "CA signed a trusted cert for $san — constraints not enforced" ;; esac
	echo "$out" | grep -qiE 'name constraint|permitted subtree|subtree violation|not permitted' \
		|| fail "expected a name-constraints rejection for $san, got: $out"
done
out=$(evil 'DNS:rnode.local,IP:10.1.2.3') || true
echo "$out" | grep -q ': OK' || fail "a .local + private-IP leaf must still verify: $out"
pass "nameConstraints enforced: public names/IPs rejected, appliance names accepted"

# D3 — no silent rotation; explicit rotation replaces the CA.
f1=$(fp)
run node-router
[ "$(fp)" = "$f1" ] || fail "a normal run must keep the existing CA"
KNOTS_LAN_IP=10.20.30.1 run node-router --leaf
[ "$(fp)" = "$f1" ] || fail "--leaf (LAN IP change) must keep the CA"
openssl x509 -in "$KNOTS_TLS_DIR/cert.pem" -noout -text | grep -q 'IP Address:10.20.30.1' || fail "--leaf must reissue for the new LAN IP"
pair_ok || fail "key/cert must match after --leaf"
run node-router --rotate-ca
[ "$(fp)" != "$f1" ] || fail "--rotate-ca must create a new CA"
openssl verify -CAfile "$KNOTS_TLS_DIR/ca.pem" "$KNOTS_TLS_DIR/cert.pem" >/dev/null 2>&1 || fail "leaf must chain to the rotated CA"
pass "existing CA kept on normal/--leaf runs; --rotate-ca replaces CA + leaf"

# A pre-P3 (v1, unconstrained) CA is kept on upgrade — no silent re-trust.
rm -rf "$KNOTS_TLS_DIR"; mkdir -p "$KNOTS_TLS_DIR"
printf '[req]\ndistinguished_name=dn\nx509_extensions=v\nprompt=no\n[dn]\nCN=Knots Appliance CA\n[v]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n' >"$W/v1.cnf"
openssl req -x509 -nodes -newkey rsa:2048 -keyout "$KNOTS_TLS_DIR/ca.key" -out "$KNOTS_TLS_DIR/ca.pem" -days 30 -config "$W/v1.cnf" 2>/dev/null
f1=$(fp)
run node-router
[ "$(fp)" = "$f1" ] || fail "an existing v1 CA must be kept (rotation only via reset / Renew)"
pass "pre-P3 CA kept until factory reset / Renew (D3)"

# P5 — a leaf expiring within 30 days is renewed.
printf '[req]\ndistinguished_name=d\nprompt=no\n[d]\nCN=node-router\n[e]\nsubjectAltName=DNS:node-router,DNS:knots-router,DNS:rnode.local,IP:192.168.1.254\n' >"$W/s.cnf"
openssl req -nodes -newkey rsa:2048 -keyout "$KNOTS_TLS_DIR/key.pem" -out "$W/s.csr" -config "$W/s.cnf" 2>/dev/null
openssl x509 -req -in "$W/s.csr" -CA "$KNOTS_TLS_DIR/ca.pem" -CAkey "$KNOTS_TLS_DIR/ca.key" -CAcreateserial \
	-CAserial "$W/s.srl" -out "$KNOTS_TLS_DIR/cert.pem" -days 10 -extfile "$W/s.cnf" -extensions e 2>/dev/null
old_end=$(openssl x509 -in "$KNOTS_TLS_DIR/cert.pem" -noout -enddate)
run node-router
[ "$(openssl x509 -in "$KNOTS_TLS_DIR/cert.pem" -noout -enddate)" != "$old_end" ] || fail "leaf expiring in 10 days must be renewed"
openssl x509 -in "$KNOTS_TLS_DIR/cert.pem" -noout -checkend 2592000 >/dev/null || fail "renewed leaf must outlive 30 days"
pair_ok || fail "key/cert must match after renewal"
[ ! -d "$KNOTS_TLS_DIR/.lock" ] || fail "lock must be released"
ls "$KNOTS_TLS_DIR" | grep -q '^\.tmp' && fail "temp dir left behind"
pass "leaf renewed before expiry; atomic key/cert; lock released"

# Wiring: rotation only via factory reset or the authenticated Settings action.
K="$ROOT/files/usr/libexec/knots"
grep -q 'node-ui-tls.sh node-router --rotate-ca' "$K/factory-reset.sh" || fail "factory reset must rotate the CA (D3)"
blk=$(awk '/^\ttls_renew\)/{f=1} f{print} f&&/^\t\t;;$/{exit}' "$K/settings-api.sh")
for need in require_mutating_post require_auth_fields '"RENEW"' '--rotate-ca'; do
	printf '%s\n' "$blk" | grep -q -- "$need" || fail "settings tls_renew must use $need"
done
grep -q 'id="btnTlsRenew"' "$ROOT/files/www/knots/settings.html" || fail "Settings needs the Renew certificate button"
others=$(grep -rln -- '--rotate-ca\|--force' "$K" "$ROOT/files/etc" | grep -v -e node-ui-tls.sh -e factory-reset.sh -e settings-api.sh || true)
for f in $others; do
	grep -n 'node-ui-tls.sh.*\(--rotate-ca\|--force\)' "$f" && fail "unexpected CA rotation caller: $f"
done
pass "CA rotation only from factory reset and authenticated Settings tls_renew"

echo "ALL PASS: test-node-ui-tls (T-NODE-TLS)"
