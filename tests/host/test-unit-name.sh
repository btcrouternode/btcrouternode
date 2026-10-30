#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-UNIT-NAME — N20 (pre-production review, 2026-10-18): unique per-unit name.
#  - rnode-XXXX from the U-Boot ethaddr, identical to what
#    factory/provision-secret.sh prints on the label; cached; never invented
#  - the HTTPS leaf carries DNS:rnode-XXXX.local, verifies under the
#    name-constrained CA, and an older leaf without it is reissued
#  - the LAN hotplug publishes it (avahi static hosts + dnsmasq /tmp/hosts);
#    nginx / shell.js / LuCI treat it as one of the router's own names
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"

name_for() { # MAC → name from the router helper (stub fw_printenv)
	printf '#!/bin/sh\necho "%s"\n' "$1" >"$W/bin/fw_printenv"; chmod +x "$W/bin/fw_printenv"
	rm -f "$W/unit-name"
	PATH="$W/bin:$PATH" KNOTS_UNIT_NAME_FILE="$W/unit-name" sh -c ". '$K/unit-name.sh'; knots_unit_name"
}
for mac in 02:11:22:33:3F:2A aa:bb:cc:dd:ee:ff 00:0c:43:00:00:01; do
	got=$(name_for "$mac")
	lower=$(printf '%s' "$mac" | tr 'A-F' 'a-f')
	label="rnode-$(echo "$lower" | tr -d : | tail -c 5)"   # provision-secret.sh's formula
	[ "$got" = "$label" ] || fail "router name '$got' != label name '$label' for $mac"
done
[ "$(cat "$W/unit-name")" = rnode-0001 ] || fail "name must be cached"
printf '#!/bin/sh\nexit 1\n' >"$W/bin/fw_printenv"
out=$(PATH="$W/bin:$PATH" KNOTS_UNIT_NAME_FILE="$W/unit-name" sh -c ". '$K/unit-name.sh'; knots_unit_name") \
	&& [ "$out" = rnode-0001 ] || fail "cached name must survive a missing ethaddr ($out)"
rm -f "$W/unit-name"
PATH="$W/bin:$PATH" KNOTS_UNIT_NAME_FILE="$W/unit-name" sh -c ". '$K/unit-name.sh'; knots_unit_name" \
	&& fail "no ethaddr and no cache must yield no name (never invent one)"
grep -q 'Address    : http://rnode-' "$ROOT/factory/provision-secret.sh" || fail "label must print the unit address"
pass "rnode-XXXX from ethaddr matches the factory label; cached; never invented"

# HTTPS leaf
command -v openssl >/dev/null 2>&1 || { echo "SKIP leaf part: no openssl"; exit 0; }
export KNOTS_TLS_DIR="$W/tls" KNOTS_WWW_DIR="$W/www" KNOTS_LAN_IP=192.168.1.254 KNOTS_LIBEXEC="$K"
sh "$K/node-ui-tls.sh" node-router >/dev/null 2>&1 || fail "node-ui-tls (no name)"
openssl x509 -in "$W/tls/cert.pem" -noout -text | grep -q 'DNS:rnode-' && fail "no unit name → no unit SAN"
KNOTS_UNIT_NAME=rnode-3f2a sh "$K/node-ui-tls.sh" node-router >/dev/null 2>&1 || fail "node-ui-tls (name)"
openssl x509 -in "$W/tls/cert.pem" -noout -text | grep -q 'DNS:rnode-3f2a.local' \
	|| fail "leaf must be reissued with DNS:rnode-3f2a.local once the name is known"
openssl verify -CAfile "$W/tls/ca.pem" "$W/tls/cert.pem" >/dev/null 2>&1 || fail "leaf must verify under the constrained CA"
pass "leaf SAN rnode-XXXX.local added (reissued when missing) and valid under the name-constrained CA"

# publishing + host rules
H="$ROOT/files/etc/hotplug.d/iface/95-knots-avahi"
grep -q '/tmp/hosts/knots-unit' "$H" || fail "hotplug must publish the unit name via dnsmasq"
# mDNS: avahi-publish -R alias (static hosts file collides — .48 / .103)
grep -q 'printf.*/etc/avahi/hosts\|>>/etc/avahi/hosts' "$H" && fail "hotplug must not put the unit name in /etc/avahi/hosts (Local name collision)"
grep -q 'knots-mdns-alias restart' "$H" || fail "hotplug must restart knots-mdns-alias after avahi"
A="$ROOT/files/etc/init.d/knots-mdns-alias"
grep -q 'avahi-publish -a -R "$unit.local" "$ip"' "$A" && grep -q 'respawn' "$A" || fail "knots-mdns-alias: avahi-publish -a -R, respawned"
grep -qx 'avahi-dbus-daemon' "$ROOT/build/packages.txt" && grep -qx 'avahi-utils' "$ROOT/build/packages.txt" \
	&& ! grep -qx 'avahi-nodbus-daemon' "$ROOT/build/packages.txt" || fail "image needs avahi-dbus-daemon + avahi-utils (not nodbus)"
grep -q 'knots-mdns-alias enable' "$ROOT/files/etc/uci-defaults/93-knots-node-ui" || fail "knots-mdns-alias not enabled"
grep -qF '"~^rnode-[0-9a-f]{4}\.local$" $host;' "$ROOT/files/etc/nginx/conf.d/knots-ui.conf" || fail "nginx \$knots_rhost must keep rnode-XXXX.local"
for f in files/www/knots/shell.js files/www/luci-static/resources/knots-return.js files/www/luci-entry.html \
	files/usr/share/ucode/luci/controller/admin/node_dashboard.uc files/usr/share/ucode/luci/template/node_dashboard.ut \
	files/usr/share/ucode/luci/template/themes/bootstrap/sysauth.ut; do
	grep -q 'rnode-\[0-9a-f\]{4}' "$ROOT/$f" || fail "$f must accept rnode-XXXX.local"
done
grep -q '"unit_name":"%s"' "$K/settings-api.sh" && grep -q 'id="unitName"' "$ROOT/files/www/knots/settings.html" \
	|| fail "Settings must show the unit address"
pass "published on LAN up; nginx / UI / LuCI keep rnode-XXXX.local; Settings shows it"
echo "ALL PASS: test-unit-name (T-UNIT-NAME)"
