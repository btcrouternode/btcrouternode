#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host check: node-ui-tls.sh produces local CA + SAN for LAN IP (F29 / N13).
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/files/usr/libexec/knots/node-ui-tls.sh"
command -v openssl >/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export KNOTS_LAN_IP=192.168.1.254
# Script writes under /etc/knots/tls and /www/knots — redirect via bind-like env override
# by running in a fake root with PATH wrappers is heavy; instead source-check + dry run
# in TMP by patching via env: copy script and substitute paths for host test.

sed -e "s|/etc/knots/tls|$TMP/tls|g" -e "s|/www/knots|$TMP/www|g" "$SCRIPT" >"$TMP/run.sh"
chmod +x "$TMP/run.sh"
sh "$TMP/run.sh" --force

test -f "$TMP/tls/ca.pem"
test -f "$TMP/tls/cert.pem"
test -f "$TMP/tls/fullchain.pem"
test -f "$TMP/www/knots-ca.crt"

# fullchain = leaf then CA
grep -q 'BEGIN CERTIFICATE' "$TMP/tls/fullchain.pem"
c1=$(grep -c 'BEGIN CERTIFICATE' "$TMP/tls/fullchain.pem")
[ "$c1" -ge 2 ] || { echo "FAIL: fullchain must include leaf+CA"; exit 1; }

openssl x509 -in "$TMP/tls/cert.pem" -noout -issuer | grep -q 'Knots Appliance CA'
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q '192.168.1.254'
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q 'node-router'
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q 'knots-router'
openssl verify -CAfile "$TMP/tls/ca.pem" "$TMP/tls/cert.pem" | grep -q OK
grep -q 'fullchain.pem' "$SCRIPT" || {
	echo "FAIL: node-ui-tls must publish fullchain (nginx :443)" >&2
	exit 1
}
grep -q 'uhttpd.main.cert="$TLS_DIR/cert.pem"' "$SCRIPT" || {
	echo "FAIL: uhttpd must get the leaf only (mbedTLS rejects the constrained CA in a chain)" >&2
	exit 1
}
grep -q 'uhttpd.main.cert' "$SCRIPT" || {
	echo "FAIL: node-ui-tls must set uhttpd.main.cert" >&2
	exit 1
}

# LAN IP change: --leaf reissues the server cert, same CA (IUE trust stays).
ca1=$(openssl x509 -in "$TMP/tls/ca.pem" -noout -fingerprint -sha256)
export KNOTS_LAN_IP=192.168.10.1
sh "$TMP/run.sh" --leaf
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q '192.168.10.1' || {
	echo "FAIL: --leaf must put the new LAN IP on the SAN" >&2
	exit 1
}
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q '192.168.1.254' && {
	echo "FAIL: --leaf must replace the old LAN IP on the SAN" >&2
	exit 1
}
ca2=$(openssl x509 -in "$TMP/tls/ca.pem" -noout -fingerprint -sha256)
[ "$ca1" = "$ca2" ] || {
	echo "FAIL: --leaf must not replace the IUE CA" >&2
	exit 1
}
openssl verify -CAfile "$TMP/tls/ca.pem" "$TMP/tls/cert.pem" | grep -q OK
grep -q -- '--leaf' "$SCRIPT" || {
	echo "FAIL: node-ui-tls must support --leaf for LAN IP change" >&2
	exit 1
}

# Cutover hold: extra SAN keeps the previous LAN IP reachable (U17 Finish).
export KNOTS_LAN_IP=192.168.50.1
export KNOTS_LAN_IP_EXTRA=192.168.1.254
sh "$TMP/run.sh" --leaf
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q '192.168.50.1' || {
	echo "FAIL: leaf must include the new LAN IP" >&2
	exit 1
}
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q '192.168.1.254' || {
	echo "FAIL: KNOTS_LAN_IP_EXTRA must stay on the SAN during alias hold" >&2
	exit 1
}
grep -q 'KNOTS_LAN_IP_EXTRA' "$SCRIPT" || {
	echo "FAIL: node-ui-tls must honour KNOTS_LAN_IP_EXTRA" >&2
	exit 1
}

echo "PASS: local CA + SAN server cert + fullchain (F29/N13 + LuCI shared TLS)"
