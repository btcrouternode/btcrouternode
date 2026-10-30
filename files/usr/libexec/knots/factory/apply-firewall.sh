#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# DMZ zone, WAN DNAT 8333 (IPv4+IPv6), LAN node-UI port, reject WAN management, UPnP off.
# SINGLE SOURCE (review N5, 2026-10-11): used by first boot (uci-defaults
# 91-knots-firewall) AND factory reset. The previous factory-reset copy had
# drifted — dmz.output ACCEPT and no device_dmz_rpc rule — so a reset left
# weaker router→DMZ isolation than a fresh flash.
# NOTE: `uci -q delete` still exits non-zero when the section is absent; with
# `set -e` that aborts the script before commit (seen on P2 bring-up).

set -e

# --keep-owner (uci-defaults on a configured unit, i.e. after a keep-settings
# sysupgrade — U3): keep the owner's LAN-wallet RPC on/off choice (Settings →
# external-rpc.sh, state on M.2) instead of silently switching it off while
# bitcoin.conf still carries the rpcauth block. Factory reset omits it → OFF.
EXT_DNAT=0
EXT_RULE=0
if [ "${1:-}" = "--keep-owner" ]; then
	[ "$(uci -q get firewall.knots_ext_rpc_dnat.enabled)" = 1 ] && EXT_DNAT=1
	[ "$(uci -q get firewall.knots_ext_rpc.enabled)" = 1 ] && EXT_RULE=1
fi

# DMZ zone (single Knots host behind veth)
uci -q delete firewall.dmz || true
uci set firewall.dmz=zone
uci set firewall.dmz.name='dmz'
uci set firewall.dmz.network='dmz'
uci set firewall.dmz.input='REJECT'
uci set firewall.dmz.output='REJECT'
uci set firewall.dmz.forward='REJECT'
uci set firewall.dmz.masq='0'

# device -> DMZ: only the UI/RPC path (TECH_SPEC §4.3); everything else REJECT
uci -q delete firewall.device_dmz_rpc || true
uci set firewall.device_dmz_rpc=rule
uci set firewall.device_dmz_rpc.name='Allow-Device-DMZ-RPC'
uci set firewall.device_dmz_rpc.dest='dmz'
uci set firewall.device_dmz_rpc.dest_ip='21.21.21.21'
uci set firewall.device_dmz_rpc.dest_port='8332'
uci set firewall.device_dmz_rpc.proto='tcp'
uci set firewall.device_dmz_rpc.family='ipv4'
uci set firewall.device_dmz_rpc.target='ACCEPT'

# DMZ egress to WAN (allow-any initially - N7)
uci -q delete firewall.dmz_wan || true
uci set firewall.dmz_wan=forwarding
uci set firewall.dmz_wan.src='dmz'
uci set firewall.dmz_wan.dest='wan'

# WAN -> DMZ P2P DNAT (IPv4)
uci -q delete firewall.knots_p2p_dnat || true
uci set firewall.knots_p2p_dnat=redirect
uci set firewall.knots_p2p_dnat.name='Knots-P2P-8333'
uci set firewall.knots_p2p_dnat.src='wan'
uci set firewall.knots_p2p_dnat.src_dport='8333'
uci set firewall.knots_p2p_dnat.dest='dmz'
uci set firewall.knots_p2p_dnat.dest_ip='21.21.21.21'
uci set firewall.knots_p2p_dnat.dest_port='8333'
uci set firewall.knots_p2p_dnat.proto='tcp'
uci set firewall.knots_p2p_dnat.family='ipv4'
uci set firewall.knots_p2p_dnat.target='DNAT'

# WAN -> DMZ P2P DNAT (IPv6 only 8333 — N6a)
uci -q delete firewall.knots_p2p_dnat6 || true
uci set firewall.knots_p2p_dnat6=redirect
uci set firewall.knots_p2p_dnat6.name='Knots-P2P-8333-IPv6'
uci set firewall.knots_p2p_dnat6.src='wan'
uci set firewall.knots_p2p_dnat6.src_dport='8333'
uci set firewall.knots_p2p_dnat6.dest='dmz'
uci set firewall.knots_p2p_dnat6.dest_ip='fd21:21:21::21'
uci set firewall.knots_p2p_dnat6.dest_port='8333'
uci set firewall.knots_p2p_dnat6.proto='tcp'
uci set firewall.knots_p2p_dnat6.family='ipv6'
uci set firewall.knots_p2p_dnat6.target='DNAT'

# LAN may reach Knots dashboard (80/443) and LuCI (8080/8443)
uci -q delete firewall.knots_ui_lan || true
uci set firewall.knots_ui_lan=rule
uci set firewall.knots_ui_lan.name='Allow-Knots-UI-LAN'
uci set firewall.knots_ui_lan.src='lan'
uci set firewall.knots_ui_lan.dest_port='80 443 21443'
uci set firewall.knots_ui_lan.proto='tcp'
uci set firewall.knots_ui_lan.target='ACCEPT'

uci -q delete firewall.luci_lan || true
uci set firewall.luci_lan=rule
uci set firewall.luci_lan.name='Allow-LuCI-LAN'
uci set firewall.luci_lan.src='lan'
uci set firewall.luci_lan.dest_port='8080 8443'
uci set firewall.luci_lan.proto='tcp'
uci set firewall.luci_lan.target='ACCEPT'

# Block WAN management surfaces (Knots UI + LuCI + legacy 21443)
uci -q delete firewall.reject_wan_luci || true
uci set firewall.reject_wan_luci=rule
uci set firewall.reject_wan_luci.name='Reject-WAN-Mgmt-UI'
uci set firewall.reject_wan_luci.src='wan'
uci set firewall.reject_wan_luci.dest_port='80 443 8080 8443 21443'
uci set firewall.reject_wan_luci.proto='tcp'
uci set firewall.reject_wan_luci.target='REJECT'

uci -q delete firewall.reject_wan_ui || true

uci -q delete firewall.reject_wan_ssh || true
uci set firewall.reject_wan_ssh=rule
uci set firewall.reject_wan_ssh.name='Reject-WAN-SSH'
uci set firewall.reject_wan_ssh.src='wan'
uci set firewall.reject_wan_ssh.dest_port='22'
uci set firewall.reject_wan_ssh.proto='tcp'
uci set firewall.reject_wan_ssh.target='REJECT'

# Do not allow LAN hosts to forward into DMZ by default (N8)
# Router-local UI->RPC uses OUTPUT and does not need lan->dmz forward.

# P2B-B: LAN Knots RPC path — OFF by default (explicit enable via external-rpc.sh)
uci -q delete firewall.knots_ext_rpc_dnat || true
uci set firewall.knots_ext_rpc_dnat=redirect
uci set firewall.knots_ext_rpc_dnat.name='Knots-RPC-LAN'
uci set firewall.knots_ext_rpc_dnat.src='lan'
uci set firewall.knots_ext_rpc_dnat.src_dport='8332'
uci set firewall.knots_ext_rpc_dnat.dest='dmz'
uci set firewall.knots_ext_rpc_dnat.dest_ip='21.21.21.21'
uci set firewall.knots_ext_rpc_dnat.dest_port='8332'
uci set firewall.knots_ext_rpc_dnat.proto='tcp'
uci set firewall.knots_ext_rpc_dnat.target='DNAT'
uci set firewall.knots_ext_rpc_dnat.enabled="$EXT_DNAT"

uci -q delete firewall.knots_ext_rpc || true
uci set firewall.knots_ext_rpc=rule
uci set firewall.knots_ext_rpc.name='Allow-LAN-Knots-RPC'
uci set firewall.knots_ext_rpc.src='lan'
uci set firewall.knots_ext_rpc.dest='dmz'
uci set firewall.knots_ext_rpc.dest_port='8332'
uci set firewall.knots_ext_rpc.proto='tcp'
uci set firewall.knots_ext_rpc.target='ACCEPT'
uci set firewall.knots_ext_rpc.enabled="$EXT_RULE"

uci -q delete firewall.reject_wan_rpc || true
uci set firewall.reject_wan_rpc=rule
uci set firewall.reject_wan_rpc.name='Reject-WAN-Knots-RPC'
uci set firewall.reject_wan_rpc.src='wan'
uci set firewall.reject_wan_rpc.dest_port='8332'
uci set firewall.reject_wan_rpc.proto='tcp'
uci set firewall.reject_wan_rpc.target='REJECT'
uci set firewall.reject_wan_rpc.enabled='1'

# P2B-C: no WAN Lightning P2P in v1 (W13) — reject even if CLN listens in DMZ
uci -q delete firewall.reject_wan_ln || true
uci set firewall.reject_wan_ln=rule
uci set firewall.reject_wan_ln.name='Reject-WAN-Lightning'
uci set firewall.reject_wan_ln.src='wan'
uci set firewall.reject_wan_ln.dest_port='9735'
uci set firewall.reject_wan_ln.proto='tcp'
uci set firewall.reject_wan_ln.target='REJECT'
uci set firewall.reject_wan_ln.enabled='1'

uci -q set upnpd.config.enabled='0' || true

uci commit firewall
uci -q commit upnpd || true

exit 0
