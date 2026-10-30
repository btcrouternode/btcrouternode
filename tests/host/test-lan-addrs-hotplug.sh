#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-LAN-ADDRS — review S11: hotplug writes the router's global IPv6 LAN
# addresses into the nginx $knots_via_lan map file (stubbed ip/ubus).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HP="$ROOT/files/etc/hotplug.d/iface/90-knots-lan-addrs"
fail() { echo "FAIL: $*" >&2; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat >"$W/bin/ubus" <<'S'
#!/bin/sh
printf '{\n\t"l3_device": "br-lan",\n\t"up": true\n}\n'
S
cat >"$W/bin/ip" <<'S'
#!/bin/sh
case "$*" in
	*"-6 -o addr show dev br-lan scope global"*)
		echo "9: br-lan    inet6 2001:db8:1:2::1/64 scope global dynamic noprefixroute"
		echo "9: br-lan    inet6 fd21:aaaa::1/60 scope global noprefixroute"
		echo "9: br-lan    inet6 2001:db8:1:2::1/64 scope global"
		;;
esac
S
chmod +x "$W/bin/ubus" "$W/bin/ip"
run() { PATH="$W/bin:$PATH" KNOTS_LAN_MAP="$W/map" ACTION=$1 INTERFACE=$2 sh "$HP"; }

run ifup wan; [ ! -e "$W/map" ] || fail "must ignore non-lan interfaces"
run ifdown lan; [ ! -e "$W/map" ] || fail "must ignore ifdown"
run ifup lan
grep -qx '"2001:db8:1:2::1" 1;' "$W/map" || fail "GUA address missing"
grep -q 'fd21:aaaa::1' "$W/map" && fail "ULA must not be written (covered by the map regex; avoids needless nginx reloads)"
[ "$(grep -c '2001:db8:1:2::1' "$W/map")" = 1 ] || fail "duplicate entries"
grep -q '/' "$W/map" && fail "prefix length leaked into map"
cp "$W/map" "$W/before"
run ifupdate lan
cmp -s "$W/map" "$W/before" || fail "unchanged addresses must leave the file untouched"
echo "PASS T-LAN-ADDRS"
