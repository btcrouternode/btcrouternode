#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# LAN 192.168.1.254, DHCP .100-.200, DMZ bridge for LXC, stock WAN/LAN ports.
# SINGLE SOURCE (review N4/N5, 2026-10-11) for first boot (uci-defaults
# 90-knots-network) and factory reset.
#   (no args)        full baseline: hostname, timezone, LAN IP/DHCP, DMZ, hosts
#   --topology-only  product plumbing only (DMZ bridge/interface). OpenWrt
#                    re-runs uci-defaults after EVERY keep-settings sysupgrade;
#                    the full baseline then silently reset an owner's LAN IP,
#                    DHCP range, hostname and timezone.

set -e

TOPOLOGY_ONLY=0
[ "${1:-}" = "--topology-only" ] && TOPOLOGY_ONLY=1

if [ "$TOPOLOGY_ONLY" = 0 ]; then
uci -q batch <<'EOF'
set system.@system[0].hostname='node-router'
set system.@system[0].timezone='UTC'

set network.lan.proto='static'
set network.lan.ipaddr='192.168.1.254'
set network.lan.netmask='255.255.255.0'

set dhcp.lan.start='100'
set dhcp.lan.limit='101'
set dhcp.lan.leasetime='12h'
EOF
fi

uci -q batch <<'EOF'
# DMZ bridge — router 21.21.21.1 / fd21:21:21::1; Knots LXC ::21 (sole service host)
set network.br_dmz=device
set network.br_dmz.name='br-dmz'
set network.br_dmz.type='bridge'
set network.br_dmz.bridge_empty='1'

set network.dmz=interface
set network.dmz.proto='static'
set network.dmz.device='br-dmz'
set network.dmz.ipaddr='21.21.21.1'
set network.dmz.netmask='255.255.255.0'
set network.dmz.ip6addr='fd21:21:21::1/64'
EOF

uci commit network
if [ "$TOPOLOGY_ONLY" = 1 ]; then
	[ -x /etc/init.d/avahi-daemon ] && /etc/init.d/avahi-daemon enable 2>/dev/null || true
	exit 0
fi
uci commit system
uci commit dhcp

# Same IUE name as uci-defaults 90-knots-network (U17/N13). Factory reset
# re-runs this script, not the one-shot defaults.
# N3 (review 2026-10-10): replace, not append-if-missing — after a Setup LAN
# change the existing line points at the old LAN IP (plus any leftover
# cutover alias line), and dnsmasq would keep serving that to clients.
# Two plain patterns: musl/busybox BRE has no \| alternation.
sed -i -e '/[[:space:]]rnode\.local$/d' -e '/[[:space:]]rnode\.local[[:space:]]/d' /etc/hosts 2>/dev/null || true
echo '192.168.1.254 rnode.local' >> /etc/hosts
[ -x /etc/init.d/avahi-daemon ] && /etc/init.d/avahi-daemon enable 2>/dev/null || true

exit 0
