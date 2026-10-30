#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Local CA + server cert for node UI :443 and LuCI :8443 (REQUIREMENTS N13).
# Browsers trust HTTPS after installing /knots-ca.crt once (served over HTTP).
# One leaf serves both nginx (Node) and uhttpd (Router settings) so one trust covers both.

set -e

TLS_DIR=${KNOTS_TLS_DIR:-/etc/knots/tls}
WWW_DIR=${KNOTS_WWW_DIR:-/www/knots}
CN="${1:-node-router}"
case "$CN" in --*) CN=node-router ;; esac
FORCE=0
LEAF=0
for a in "$@"; do
	# --force / --rotate-ca: new CA + leaf. Only for factory reset and the
	# Settings "Renew certificate" action — every client must re-install the
	# CA afterwards (decision D3: never silently during an upgrade).
	case "$a" in --force|--rotate-ca) FORCE=1 ;; esac
	# New server cert only (LAN IP change). Never replace the CA the
	# visitor already installed during IUE (N13).
	[ "$a" = "--leaf" ] && LEAF=1
done

LAN_IP="${KNOTS_LAN_IP:-192.168.1.254}"
LAN_IP_EXTRA="${KNOTS_LAN_IP_EXTRA:-}"
# Prefer live LAN IP when available unless the caller set KNOTS_LAN_IP.
if [ -z "${KNOTS_LAN_IP:-}" ] && command -v uci >/dev/null 2>&1; then
	_lip=$(uci -q get network.lan.ipaddr 2>/dev/null || true)
	[ -n "$_lip" ] && LAN_IP=$_lip
fi
WWW_CA=$WWW_DIR/knots-ca.crt
DAYS_CA=3650
DAYS_SRV=825
# P5 — renew the leaf when it expires within this many seconds (30 days).
LEAF_RENEW_SEC=${KNOTS_LEAF_RENEW_SEC:-2592000}

mkdir -p "$TLS_DIR"
chmod 755 "$TLS_DIR"

# P5 — one writer at a time (boot, LAN cutover and Settings can overlap);
# a stale lock (owner gone) is reclaimed.
LOCK="$TLS_DIR/.lock"
_i=0
while ! mkdir "$LOCK" 2>/dev/null; do
	_o=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -n "$_o" ] && ! kill -0 "$_o" 2>/dev/null; then
		rm -rf "$LOCK"
		continue
	fi
	_i=$((_i + 1))
	[ "$_i" -ge 60 ] && { echo "node-ui-tls: lock busy" >&2; exit 1; }
	sleep 1
done
echo "$$" >"$LOCK/pid"

command -v openssl >/dev/null 2>&1 || {
	echo "node-ui-tls: openssl missing" >&2
	exit 1
}

cert_text() {
	openssl x509 -in "$TLS_DIR/cert.pem" -noout -text 2>/dev/null || true
}

need_ca=0
# N20: the unit's own name for the leaf SAN (empty off-device / unknown MAC)
UNIT_NAME=
if [ -f "${KNOTS_LIBEXEC:-/usr/libexec/knots}/unit-name.sh" ]; then
	# shellcheck disable=SC1091
	. "${KNOTS_LIBEXEC:-/usr/libexec/knots}/unit-name.sh"
	UNIT_NAME=$(knots_unit_name 2>/dev/null || true)
fi
need_leaf=0
[ "$FORCE" = "1" ] && need_ca=1 && need_leaf=1
[ "$LEAF" = "1" ] && need_leaf=1
if [ ! -f "$TLS_DIR/ca.pem" ] || [ ! -f "$TLS_DIR/ca.key" ]; then
	need_ca=1
	need_leaf=1
fi
if [ ! -f "$TLS_DIR/cert.pem" ] || [ ! -f "$TLS_DIR/key.pem" ]; then
	need_leaf=1
fi
if [ "$need_leaf" = "0" ] && [ -f "$TLS_DIR/cert.pem" ]; then
	_txt=$(cert_text)
	# Must be issued by our CA and cover LAN IP + hostnames used by Node + LuCI
	echo "$_txt" | grep -E "IP Address:${LAN_IP}([^0-9]|$)" >/dev/null || need_leaf=1
	echo "$_txt" | grep -q 'node-router' || need_leaf=1
	echo "$_txt" | grep -q 'knots-router' || need_leaf=1
	echo "$_txt" | grep -q 'rnode\.local' || need_leaf=1
	if [ -n "$UNIT_NAME" ]; then
		echo "$_txt" | grep -q "DNS:${UNIT_NAME}\.local" || need_leaf=1
	fi
	# P5 — renew before expiry (825-day leaf; nothing checked this before)
	openssl x509 -in "$TLS_DIR/cert.pem" -noout -checkend "$LEAF_RENEW_SEC" >/dev/null 2>&1 \
		|| need_leaf=1
	if ! openssl x509 -in "$TLS_DIR/cert.pem" -noout -issuer 2>/dev/null | grep -q 'Knots Appliance CA'; then
		need_ca=1
		need_leaf=1
	fi
fi

# Leaf + CA for nginx/uhttpd — some clients walk chain better with fullchain (N13)
write_fullchain() {
	[ -f "$TLS_DIR/cert.pem" ] && [ -f "$TLS_DIR/ca.pem" ] || return 0
	cat "$TLS_DIR/cert.pem" "$TLS_DIR/ca.pem" >"$TLS_DIR/fullchain.pem"
	chmod 644 "$TLS_DIR/fullchain.pem"
}

# L-node-ui-tls — .mobileconfig PayloadUUID must be hex-only UUID-shaped.
# Derive deterministically from the CA SHA-256 fingerprint (stable per install);
# fmt_uuid maps 32 hex chars → 8-4-4-4-12 with v4/version + variant nibbles.
fmt_uuid() {
	printf '%s' "$1" | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{3\}\)\(.\{3\}\)\(.\{12\}\).*/\1-\2-4\3-9\4-\5/'
}

publish_ca() {
	mkdir -p "$WWW_DIR" "$WWW_DIR/tls"
	cp "$TLS_DIR/ca.pem" "$WWW_CA"
	chmod 644 "$WWW_CA"
	write_fullchain

	# DER (.cer) — some Android / Windows installers prefer this
	if openssl x509 -in "$TLS_DIR/ca.pem" -outform DER -out $WWW_DIR/tls/knots-ca.cer 2>/dev/null; then
		chmod 644 $WWW_DIR/tls/knots-ca.cer
	fi

	# iOS / macOS configuration profile (com.apple.security.root) — zero-tech install
	b64=
	b64=$(openssl x509 -in "$TLS_DIR/ca.pem" -outform DER 2>/dev/null | openssl base64 -A 2>/dev/null) || true
	if [ -z "$b64" ]; then
		b64=$(openssl x509 -in "$TLS_DIR/ca.pem" -outform DER 2>/dev/null | openssl enc -base64 2>/dev/null | tr -d '\n\r') || true
	fi
	if [ -n "$b64" ]; then
		# Fixed hex-only fallbacks; replaced by CA-fingerprint-derived UUIDs below
		uuid_cert="7c3e9a12-4b8f-4d21-9e6a-01ca0001ca01"
		uuid_prof="7c3e9a12-4b8f-4d21-9e6a-01ca0001de01"
		_fp=$(openssl x509 -in "$TLS_DIR/ca.pem" -noout -fingerprint -sha256 2>/dev/null \
			| sed 's/.*=//; s/://g' | tr 'A-F' 'a-f' | tr -dc 'a-f0-9')
		_h1=$(printf '%s' "$_fp" | cut -c1-32)
		_h2=$(printf '%s' "$_fp" | cut -c33-64)
		if [ "${#_h1}" -eq 32 ] && [ "${#_h2}" -eq 32 ]; then
			uuid_cert=$(fmt_uuid "$_h1")
			uuid_prof=$(fmt_uuid "$_h2")
		fi
		cat >$WWW_DIR/tls/ios-profile.mobileconfig <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>PayloadCertificateFileName</key>
			<string>knots-ca.crt</string>
			<key>PayloadContent</key>
			<data>${b64}</data>
			<key>PayloadDescription</key>
			<string>Trusts HTTPS for your Bitcoin Node home router (Node UI and Router settings).</string>
			<key>PayloadDisplayName</key>
			<string>Bitcoin Node CA</string>
			<key>PayloadIdentifier</key>
			<string>org.bitcoinknots.appliance.ca</string>
			<key>PayloadType</key>
			<string>com.apple.security.root</string>
			<key>PayloadUUID</key>
			<string>${uuid_cert}</string>
			<key>PayloadVersion</key>
			<integer>1</integer>
		</dict>
	</array>
	<key>PayloadDescription</key>
	<string>One-time HTTPS trust for your Bitcoin Node appliance (including Router settings).</string>
	<key>PayloadDisplayName</key>
	<string>Bitcoin Node HTTPS Trust</string>
	<key>PayloadIdentifier</key>
	<string>org.bitcoinknots.appliance.trust</string>
	<key>PayloadRemovalDisallowed</key>
	<false/>
	<key>PayloadType</key>
	<string>Configuration</string>
	<key>PayloadUUID</key>
	<string>${uuid_prof}</string>
	<key>PayloadVersion</key>
	<integer>1</integer>
</dict>
</plist>
EOF
		chmod 644 $WWW_DIR/tls/ios-profile.mobileconfig
	fi

	# .109's Terminal window file: macOS would not open it (owner test,
	# 2026-10-25) — Macs use the Script Editor link (tls-os.js). Remove leftovers.
	rm -f $WWW_DIR/tls/rnode-secure-connection.terminal

	# Ubuntu / Debian / Mint (owner, 2026-10-25): the secure-connection
	# package — App Center → Install → password. Rebuilt when the CA changes.
	_deb=$WWW_DIR/tls/rnode-secure-connection.deb
	if [ ! -f "$_deb" ] || [ "$TLS_DIR/ca.pem" -nt "$_deb" ]; then
		sh "${KNOTS_LIBEXEC:-/usr/libexec/knots}/mk-trust-deb.sh" "$TLS_DIR/ca.pem" "${UNIT_NAME:-rnode}" "$_deb" \
			>/dev/null 2>&1 || logger -t node-ui-tls "secure-connection package not built" 2>/dev/null || true
	fi
}

# Point LuCI (uhttpd :8443) at the same leaf as nginx :443 (N13 / U1a).
# Leaf only: uhttpd's mbedTLS rejects a chain containing the P3 CA (critical
# nameConstraints) — LuCI crash-looped on .83. nginx (OpenSSL) keeps fullchain.
apply_uhttpd_tls() {
	[ -f /etc/config/uhttpd ] || return 0
	write_fullchain
	[ -f "$TLS_DIR/cert.pem" ] && [ -f "$TLS_DIR/key.pem" ] || return 0
	uci -q set uhttpd.main.cert="$TLS_DIR/cert.pem"
	uci -q set uhttpd.main.key="$TLS_DIR/key.pem"
	uci -q commit uhttpd
	if [ -x /etc/init.d/uhttpd ]; then
		/etc/init.d/uhttpd reload 2>/dev/null || /etc/init.d/uhttpd restart 2>/dev/null || true
	fi
}

gen_leaf() {
	TMP="$1"
	cat >"$TMP/server.cnf" <<EOF
[req]
distinguished_name = dn
req_extensions = v3_req
prompt = no

[dn]
CN = ${CN}
O = Bitcoin Knots Appliance
C = XX

[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt
subjectKeyIdentifier = hash

[alt]
DNS.1 = ${CN}
DNS.2 = ${CN}.lan
DNS.3 = node-router
DNS.4 = node-router.lan
DNS.5 = knots-router
DNS.6 = knots-router.lan
DNS.7 = localhost
DNS.8 = rnode.local
IP.1 = ${LAN_IP}
IP.2 = 127.0.0.1
EOF
	# N20: the unit's own LAN name (rnode-XXXX.local, inside the CA's
	# DNS:local constraint).
	if [ -n "$UNIT_NAME" ]; then
		printf 'DNS.9 = %s.local\n' "$UNIT_NAME" >>"$TMP/server.cnf"
	fi
	if [ -n "$LAN_IP_EXTRA" ] && [ "$LAN_IP_EXTRA" != "$LAN_IP" ]; then
		printf 'IP.3 = %s\n' "$LAN_IP_EXTRA" >>"$TMP/server.cnf"
	fi

	# P5 — build key + cert in $TMP and move them in together: the live
	# key.pem was overwritten before the cert was signed, so a signing
	# failure or a concurrent run left nginx/uhttpd with a mismatched pair.
	openssl req -nodes -newkey rsa:2048 \
		-keyout "$TMP/key.pem" \
		-out "$TMP/server.csr" \
		-config "$TMP/server.cnf" \
		2>/dev/null

	openssl x509 -req \
		-in "$TMP/server.csr" \
		-CA "$TLS_DIR/ca.pem" \
		-CAkey "$TLS_DIR/ca.key" \
		-CAcreateserial \
		-out "$TMP/cert.pem" \
		-days "$DAYS_SRV" \
		-extfile "$TMP/server.cnf" \
		-extensions v3_req \
		2>/dev/null

	chmod 600 "$TMP/key.pem"
	chmod 644 "$TMP/cert.pem"
	mv -f "$TMP/key.pem" "$TLS_DIR/key.pem"
	mv -f "$TMP/cert.pem" "$TLS_DIR/cert.pem"
	rm -f "$TLS_DIR/ca.srl" "$TMP/ca.srl" 2>/dev/null || true
}

if [ "$need_ca" = "0" ] && [ "$need_leaf" = "0" ]; then
	trap 'rm -rf "$LOCK"' EXIT HUP INT TERM
	publish_ca
	apply_uhttpd_tls
	exit 0
fi

TMP="$TLS_DIR/.tmp.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP" "$LOCK"' EXIT HUP INT TERM

if [ "$need_ca" = "1" ]; then
	cat >"$TMP/ca.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3_ca
prompt = no

[dn]
CN = Knots Appliance CA
O = Bitcoin Knots Appliance
C = XX

[v3_ca]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
# P3 / D3 (review 2026-10-10) — the CA can only vouch for this appliance's own
# names and private/loopback IPs. Clients install it as a trusted root; an
# unconstrained CA whose key leaked (it lives on the router and in
# keep-settings backups) could impersonate ANY site — bank, exchange — to
# every one of them. Browsers and OS trust stores enforce these constraints.
nameConstraints = critical,@nc

[nc]
permitted;DNS.1 = node-router
permitted;DNS.2 = knots-router
permitted;DNS.3 = localhost
permitted;DNS.4 = local
permitted;DNS.5 = lan
permitted;IP.1 = 10.0.0.0/255.0.0.0
permitted;IP.2 = 172.16.0.0/255.240.0.0
permitted;IP.3 = 192.168.0.0/255.255.0.0
permitted;IP.4 = 127.0.0.0/255.0.0.0
EOF

	openssl req -x509 -nodes -newkey rsa:2048 \
		-keyout "$TMP/ca.key" \
		-out "$TMP/ca.pem" \
		-days "$DAYS_CA" \
		-config "$TMP/ca.cnf" \
		2>/dev/null

	chmod 600 "$TMP/ca.key"
	chmod 644 "$TMP/ca.pem"
	mv -f "$TMP/ca.key" "$TLS_DIR/ca.key"
	mv -f "$TMP/ca.pem" "$TLS_DIR/ca.pem"
	need_leaf=1
fi

if [ "$need_leaf" = "1" ]; then
	gen_leaf "$TMP"
fi

# v2 = name-constrained CA (P3). A v1 CA is kept until factory reset or an
# explicit Settings "Renew certificate" — clients would have to re-install.
if [ "$need_ca" = "1" ]; then
	echo "local-ca-v2" >"$TLS_DIR/.tls-layout"
fi
publish_ca
apply_uhttpd_tls

# Reload nginx so :443 picks up a replaced leaf
/usr/libexec/knots/nginx-apply.sh 2>/dev/null || true

logger -t knots-node-ui "TLS local CA + server cert (SAN ${LAN_IP}, node-router, knots-router, rnode.local${UNIT_NAME:+, $UNIT_NAME.local}) → nginx+uhttpd"
exit 0
