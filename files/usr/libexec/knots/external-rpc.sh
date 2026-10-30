#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# P2B-B — explicit external-wallet RPC access (W4/W9/W10).
# Default OFF: no LAN path to Knots RPC. Enable = LAN DNAT :8332 → DMZ + rpcauth.

set -e

. /usr/libexec/knots/rpc.sh

STATE_FILE=/mnt/bitcoin/.external-rpc-enabled
CRED_FILE=/mnt/bitcoin/.external-rpc.cred
CONF=/srv/lxc/knots/rootfs/etc/bitcoin/bitcoin.conf
# Markers must match bitcoin-conf-lib.sh BEGIN_EXT/END_EXT so Settings conf
# writes preserve (and can strip) this block. Legacy: '# BEGIN-EXTERNAL-RPC'.
BEGIN='# BEGIN knots-external-rpc'
END='# END knots-external-rpc'
LEGACY_BEGIN='# BEGIN-EXTERNAL-RPC'
LEGACY_END='# END-EXTERNAL-RPC'
RPC_USER="${EXTERNAL_RPC_USER:-extwallet}"

log() { logger -t external-rpc "$*"; }

fw_set() {
	# $1 = 0|1
	en=$1
	uci -q set firewall.knots_ext_rpc_dnat.enabled="$en" || true
	uci -q set firewall.knots_ext_rpc.enabled="$en" || true
	uci -q set firewall.reject_wan_rpc.enabled=1 || true
	uci commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1 || true
}

fw_ensure_sections() {
	# Idempotent UCI (also in 91-knots-firewall for images)
	if ! uci -q get firewall.knots_ext_rpc_dnat >/dev/null 2>&1; then
		uci set firewall.knots_ext_rpc_dnat=redirect
		uci set firewall.knots_ext_rpc_dnat.name='Knots-RPC-LAN'
		uci set firewall.knots_ext_rpc_dnat.src='lan'
		uci set firewall.knots_ext_rpc_dnat.src_dport='8332'
		uci set firewall.knots_ext_rpc_dnat.dest='dmz'
		uci set firewall.knots_ext_rpc_dnat.dest_ip='21.21.21.21'
		uci set firewall.knots_ext_rpc_dnat.dest_port='8332'
		uci set firewall.knots_ext_rpc_dnat.proto='tcp'
		uci set firewall.knots_ext_rpc_dnat.target='DNAT'
		uci set firewall.knots_ext_rpc_dnat.enabled='0'
	fi
	if ! uci -q get firewall.knots_ext_rpc >/dev/null 2>&1; then
		uci set firewall.knots_ext_rpc=rule
		uci set firewall.knots_ext_rpc.name='Allow-LAN-Knots-RPC'
		uci set firewall.knots_ext_rpc.src='lan'
		uci set firewall.knots_ext_rpc.dest='dmz'
		uci set firewall.knots_ext_rpc.dest_port='8332'
		uci set firewall.knots_ext_rpc.proto='tcp'
		uci set firewall.knots_ext_rpc.target='ACCEPT'
		uci set firewall.knots_ext_rpc.enabled='0'
	fi
	if ! uci -q get firewall.reject_wan_rpc >/dev/null 2>&1; then
		uci set firewall.reject_wan_rpc=rule
		uci set firewall.reject_wan_rpc.name='Reject-WAN-Knots-RPC'
		uci set firewall.reject_wan_rpc.src='wan'
		uci set firewall.reject_wan_rpc.dest_port='8332'
		uci set firewall.reject_wan_rpc.proto='tcp'
		uci set firewall.reject_wan_rpc.target='REJECT'
		uci set firewall.reject_wan_rpc.enabled='1'
	fi
	uci commit firewall
}

strip_conf_block() {
	[ -f "$CONF" ] || return 0
	tmp=$(mktemp)
	awk -v b="$BEGIN" -v e="$END" -v lb="$LEGACY_BEGIN" -v le="$LEGACY_END" '
		$0 == b || $0 == lb {skip=1; next}
		$0 == e || $0 == le {skip=0; next}
		!skip {print}
	' "$CONF" >"$tmp"
	mv "$tmp" "$CONF"
}

gen_cred() {
	pass=$(openssl rand -hex 16)
	salt=$(openssl rand -hex 16)
	# Bitcoin rpcauth: HMAC_SHA256(key=salt, msg=password)
	hmac=$(printf '%s' "$pass" | openssl dgst -sha256 -hmac "$salt" | awk '{print $NF}')
	printf '%s\n%s\n' "$RPC_USER" "$pass" >"$CRED_FILE"
	chmod 600 "$CRED_FILE"
	AUTH_LINE="rpcauth=${RPC_USER}:${salt}\$${hmac}"
	echo "$AUTH_LINE"
}

conf_has_external() {
	grep -q "^${BEGIN}$" "$CONF" 2>/dev/null
}

conf_install_auth() {
	auth_line=$1
	strip_conf_block
	{
		echo ""
		echo "$BEGIN"
		echo "$auth_line"
		echo "rpcallowip=192.168.1.0/24"
		echo "$END"
	} >>"$CONF"
}

restart_bitcoind_graceful() {
	# Reuse shared controller (TECH_SPEC §7.4.4 / Settings)
	# shellcheck disable=SC1091
	. /usr/libexec/knots/bitcoind-ctl.sh
	bitcoind_ctl_restart
}

is_enabled() {
	[ -f "$STATE_FILE" ] || return 1
	en=$(uci -q get firewall.knots_ext_rpc_dnat.enabled 2>/dev/null || echo 0)
	[ "$en" = "1" ]
}

cmd_status() {
	fw_ensure_sections
	configured=false
	conf_has_external && configured=true
	[ -f "$CRED_FILE" ] && configured=true
	enabled=false
	is_enabled && enabled=true
	user=""
	[ -f "$CRED_FILE" ] && user=$(sed -n '1p' "$CRED_FILE")
	printf '{"ok":true,"enabled":%s,"configured":%s,"user":"%s","host":"192.168.1.254","port":8332,"wallet":"%s"}\n' \
		"$enabled" "$configured" "$(json_escape "${user:-$RPC_USER}")" "$(json_escape "${WALLET_NAME:-appliance}")"
}

cmd_enable() {
	fw_ensure_sections
	need_restart=false
	auth_line=""
	if ! conf_has_external || [ ! -f "$CRED_FILE" ]; then
		auth_line=$(gen_cred)
		conf_install_auth "$auth_line"
		need_restart=true
	fi
	if [ "$need_restart" = true ]; then
		restart_bitcoind_graceful || {
			printf '{"ok":false,"error":"bitcoind_restart","message":"rpcauth installed but bitcoind RPC not ready yet — wait and retry status"}\n'
			return 0
		}
	fi
	fw_set 1
	date -u +"%Y-%m-%dT%H:%M:%SZ" >"$STATE_FILE"
	user=$(sed -n '1p' "$CRED_FILE")
	pass=$(sed -n '2p' "$CRED_FILE")
	printf '{"ok":true,"enabled":true,"host":"192.168.1.254","port":8332,"user":"%s","password":"%s","wallet":"%s","restarted":%s,"warning":"LAN-only. Disable when done. Anyone on your LAN with these credentials can use Knots RPC."}\n' \
		"$(json_escape "$user")" "$(json_escape "$pass")" \
		"$(json_escape "${WALLET_NAME:-appliance}")" \
		"$need_restart"
}

cmd_disable() {
	fw_ensure_sections
	fw_set 0
	rm -f "$STATE_FILE"
	# Phase 2 posture — also strip the rpcauth block so the next bitcoind
	# start runs without external RPC (known issue: disable used to leave it)
	if conf_has_external || grep -q "^${LEGACY_BEGIN}$" "$CONF" 2>/dev/null; then
		strip_conf_block
		log "disable: stripped rpcauth block from bitcoin.conf"
	fi
	printf '{"ok":true,"enabled":false,"message":"LAN RPC path closed; credentials retained for next enable"}\n'
}

cmd_rotate() {
	fw_ensure_sections
	auth_line=$(gen_cred)
	conf_install_auth "$auth_line"
	restart_bitcoind_graceful || {
		printf '{"ok":false,"error":"bitcoind_restart","message":"password rotated in conf but RPC not ready"}\n'
		return 0
	}
	fw_set 1
	date -u +"%Y-%m-%dT%H:%M:%SZ" >"$STATE_FILE"
	user=$(sed -n '1p' "$CRED_FILE")
	pass=$(sed -n '2p' "$CRED_FILE")
	printf '{"ok":true,"enabled":true,"host":"192.168.1.254","port":8332,"user":"%s","password":"%s","rotated":true}\n' \
		"$(json_escape "$user")" "$(json_escape "$pass")"
}

case "${1:-status}" in
	status) cmd_status ;;
	enable) cmd_enable ;;
	disable) cmd_disable ;;
	rotate) cmd_rotate ;;
	*)
		echo "Usage: $0 status|enable|disable|rotate" >&2
		exit 2
		;;
esac
