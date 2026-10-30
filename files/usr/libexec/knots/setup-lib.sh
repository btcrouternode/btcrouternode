#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# First-run Setup helpers — TECH_SPEC §7.6 / U17.
# Reuse OpenWrt passwd, UCI network/wireless/dhcp, node-impl.sh.

SETUP_COMPLETE=/etc/knots/setup-complete
SETUP_PASSWORD_DONE=/etc/knots/setup-password-done
SETUP_LOCALE_DONE=/etc/knots/setup-locale-done
SETUP_PENDING_DIR=/etc/knots/setup-pending
# Legacy shared factory password (R13). Still the root password on UNLABELLED
# units (no per-device secret) and always refused as a "new" password.
FACTORY_PASS=knotsnode21
LEGACY_FACTORY_PASS=$FACTORY_PASS
# P1 / D1 (review 2026-10-10): per-device factory secret = HMAC(factory key,
# ethaddr), written at production (factory/install-emmc-from-sd.sh phase 4)
# into the U-Boot env as knots_secret — survives factory reset AND
# sysupgrade -n — and printed on the label. Mirrored here for the rare case
# the U-Boot env is wiped (kept across keep-settings upgrades via keep.d).
FACTORY_SECRET_MIRROR=${FACTORY_SECRET_MIRROR:-/etc/knots/factory-secret}
# hostapd rejects country_code 00 (ieee80211d). Factory AP uses AU until IUE locale.
FACTORY_WIFI_COUNTRY=AU

setup_is_complete() {
	[ -f "$SETUP_COMPLETE" ]
}

setup_password_done() {
	[ -f "$SETUP_PASSWORD_DONE" ]
}

setup_mark_password_done() {
	mkdir -p /etc/knots
	: >"$SETUP_PASSWORD_DONE"
}

setup_mark_complete() {
	mkdir -p /etc/knots
	: >"$SETUP_COMPLETE"
	rm -f "$SETUP_PASSWORD_DONE" 2>/dev/null || true
	# Clear factory-reset pending so gate stops forcing /reset.html
	# shellcheck disable=SC1091
	. /usr/libexec/knots/factory-reset-ui.sh 2>/dev/null || true
	if command -v factory_reset_ui_clear >/dev/null 2>&1; then
		factory_reset_ui_clear
	fi
	# First-use captive portal ends with Setup (captive-portal.sh)
	[ -x /usr/libexec/knots/captive-portal.sh ] && /usr/libexec/knots/captive-portal.sh off >/dev/null 2>&1
	return 0
}

# N3 + U17 — factory reset must re-gate Setup (IUE); never touch M.2.
setup_clear_markers() {
	rm -f "$SETUP_COMPLETE" "$SETUP_PASSWORD_DONE" "$SETUP_LOCALE_DONE" 2>/dev/null || true
	# Also clear a pending LAN-change marker (else the next IUE run sees a
	# phantom reboot request from a change the reset already reverted).
	rm -f /tmp/knots/setup-lan-newip /etc/knots/setup-lan-newip /tmp/knots/setup-lan-oldip 2>/dev/null || true
	rm -rf "$SETUP_PENDING_DIR" 2>/dev/null || true
}

# S7 (review 2026-10-10) — byte-level input checks. Values come from
# urldecode, so %0A / %00-style bytes arrive here. A newline in a Wi-Fi key or
# SSID injects lines into the generated hostapd/UCI config; in a password it
# adds a second "user:pass" line to chpasswd.
# The trailing "x" sentinels stop $( ) from stripping a newline we are
# looking for.
setup_has_ctl() { # true if $1 contains a control byte (0x01-0x1f, 0x7f)
	[ "$(printf '%sx' "$1" | tr -d '\001-\037\177')" != "$(printf '%sx' "$1")" ]
}
setup_is_printable_ascii() { # every byte in 0x20-0x7e
	[ "$(printf '%s' "$1" | tr -d ' -~'; echo x)" = x ]
}
setup_byte_len() {
	printf '%s' "$1" | wc -c | tr -d ' '
}

# xxxx-xxxx-xxxx from a 31-symbol alphabet without look-alikes (0 1 i l o).
knots_secret_valid() {
	printf '%s' "$1" | grep -Eq '^[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}$'
}

# Prints the per-device secret; returns 1 on an unlabelled unit.
knots_factory_secret() {
	_ks=$(fw_printenv -n knots_secret 2>/dev/null || true)
	if knots_secret_valid "$_ks"; then
		if [ "$(cat "$FACTORY_SECRET_MIRROR" 2>/dev/null)" != "$_ks" ]; then
			mkdir -p "${FACTORY_SECRET_MIRROR%/*}"
			( umask 077; printf '%s\n' "$_ks" >"$FACTORY_SECRET_MIRROR" ) 2>/dev/null || true
		fi
		printf '%s\n' "$_ks"
		return 0
	fi
	_ks=
	[ -f "$FACTORY_SECRET_MIRROR" ] && _ks=$(tr -d '\r\n' <"$FACTORY_SECRET_MIRROR")
	if knots_secret_valid "$_ks"; then
		printf '%s\n' "$_ks"
		return 0
	fi
	return 1
}

knots_has_factory_secret() {
	knots_factory_secret >/dev/null
}

# Factory root (and Wi-Fi) password: the per-device secret, else legacy.
knots_factory_password() {
	knots_factory_secret || printf '%s\n' "$LEGACY_FACTORY_PASS"
}

# Neither the legacy shared password nor this unit's label secret may be
# chosen as the "new" password in Setup.
setup_is_factory_password() {
	[ "$1" = "$LEGACY_FACTORY_PASS" ] && return 0
	_fs=$(knots_factory_secret 2>/dev/null) || return 1
	[ "$1" = "$_fs" ]
}

# Same pattern as factory/apply-password.sh — set root password from arg.
# Must not write to stdout: CGI Setup API returns JSON on the same stream.
setup_set_root_password() {
	pass=$1
	[ -n "$pass" ] || return 1
	[ "${#pass}" -ge 8 ] || return 1
	! setup_has_ctl "$pass" || return 1
	! setup_is_factory_password "$pass" || return 2
	if command -v chpasswd >/dev/null 2>&1; then
		printf 'root:%s\n' "$pass" | chpasswd >/dev/null 2>&1 || return 1
	else
		# busybox passwd prints prompts on stdout — discard them
		printf '%s\n%s\n' "$pass" "$pass" | passwd root >/dev/null 2>&1 || return 1
	fi
	setup_mark_password_done
	return 0
}

setup_wifi_available() {
	uci -q show wireless 2>/dev/null | grep -q "wireless\.radio\|wifi-device"
}

# R13/R7 — same documented factory string as admin password.
setup_wifi_is_factory_key() {
	setup_is_factory_password "$1"
}

setup_wifi_current_key() {
	uci -q get wireless.@wifi-iface[0].key 2>/dev/null || true
}

setup_wifi_current_ssid() {
	uci -q get wireless.@wifi-iface[0].ssid 2>/dev/null || echo rnode
}

setup_pending_init() {
	mkdir -p "$SETUP_PENDING_DIR"
	chmod 700 "$SETUP_PENDING_DIR" 2>/dev/null || true
}

setup_pending_set() {
	k=$1
	v=$2
	case "$k" in
		*[!a-z0-9_]*) return 1 ;;
	esac
	setup_pending_init
	printf '%s' "$v" >"$SETUP_PENDING_DIR/$k"
	chmod 600 "$SETUP_PENDING_DIR/$k" 2>/dev/null || true
}

setup_pending_get() {
	k=$1
	[ -f "$SETUP_PENDING_DIR/$k" ] || return 1
	cat "$SETUP_PENDING_DIR/$k"
}

setup_pending_has() {
	[ -f "$SETUP_PENDING_DIR/$1" ]
}

setup_pending_clear() {
	rm -rf "$SETUP_PENDING_DIR" 2>/dev/null || true
}

# hostapd ubus objects (one per AP iface: hostapd.phy0-ap0, …). wpad-basic
# ships hostapd's ubus API; hostapd_cli and brctl are NOT on the image.
setup_hostapd_objs() {
	ubus list 'hostapd.*' 2>/dev/null
}

# True when this Setup HTTP client is a Wi‑Fi station (bridged AP), not Ethernet.
# No LAN-port carrier → Wi‑Fi (R7: phone IUE with no cable). Do not call `iw`
# here: nl80211 dumps can stall the CGI past the Wi‑Fi save timeout.
# C4/K1 (review 2026-10-11): the old bridge-port lookup compared hex
# brport/port_no with decimal brctl output and used brctl (absent) → every
# Ethernet client was classed as Wi-Fi. Ask hostapd for its stations instead.
setup_client_on_wifi() {
	addr=${HTTP_X_REAL_IP:-}
	[ -n "$addr" ] || addr=${REMOTE_ADDR:-}
	case "$addr" in
		""|127.*|::1) return 1 ;;
	esac
	eth=0
	for n in lan1 lan2 lan3; do
		[ -e "/sys/class/net/$n/carrier" ] || continue
		[ "$(cat "/sys/class/net/$n/carrier" 2>/dev/null)" = 1 ] && eth=1
	done
	[ "$eth" = 1 ] || return 0
	mac=$(awk -v ip="$addr" '$1==ip && $4!="00:00:00:00:00:00" {print $4; exit}' /proc/net/arp)
	[ -n "$mac" ] || return 0
	mac=$(printf '%s' "$mac" | tr 'A-F' 'a-f')
	for obj in $(setup_hostapd_objs); do
		ubus call "$obj" get_clients 2>/dev/null | tr 'A-F' 'a-f' | grep -q "\"$mac\"" && return 0
	done
	return 1
}

setup_wan_apply_dhcp() {
	uci -q set network.wan=interface
	uci -q set network.wan.proto='dhcp'
	uci -q delete network.wan.username 2>/dev/null || true
	uci -q delete network.wan.password 2>/dev/null || true
	uci -q delete network.wan.service 2>/dev/null || true
	uci commit network
	ifup wan 2>/dev/null || /etc/init.d/network reload 2>/dev/null || true
}

setup_wan_apply_pppoe() {
	user=$1
	pass=$2
	[ -n "$user" ] && [ -n "$pass" ] || return 1
	uci -q set network.wan=interface
	uci -q set network.wan.proto='pppoe'
	uci -q set network.wan.username="$user"
	uci -q set network.wan.password="$pass"
	uci commit network
	ifup wan 2>/dev/null || /etc/init.d/network reload 2>/dev/null || true
}

# Prints: up|down proto ipv4_or_empty
setup_wan_status_line() {
	proto=$(uci -q get network.wan.proto 2>/dev/null || echo dhcp)
	ipv4=
	up=false
	js=$(ubus call network.interface.wan status 2>/dev/null || true)
	if echo "$js" | grep -q '"up": *true'; then
		up=true
	fi
	ipv4=$(echo "$js" | sed -n 's/.*"address": *"\([0-9.]*\)".*/\1/p' | head -1)
	[ -n "$ipv4" ] && up=true
	printf '%s %s %s' "$up" "$proto" "$ipv4"
}

# WPA2-Personal passphrase: IEEE 802.11i / 802.11 — 8..63 ASCII (32–126).
# Default SSID: rnode (U6/R7). Apply to every radio + AP iface (dual-band).
setup_wifi_validate() {
	ssid=$1
	key=$2
	country=$3
	[ -n "$ssid" ] || return 1
	# SSID: 1-32 BYTES (802.11), UTF-8 allowed, no control bytes.
	[ "$(setup_byte_len "$ssid")" -le 32 ] || return 1
	! setup_has_ctl "$ssid" || return 1
	# WPA2 passphrase: 8-63 printable ASCII (IEEE 802.11i).
	[ "${#key}" -ge 8 ] || return 1
	[ "${#key}" -le 63 ] || return 1
	setup_is_printable_ascii "$key" || return 1
	country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')
	case "$country" in
		00|""|[A-Z][A-Z]) ;;
		*) return 1 ;;
	esac
	return 0
}

setup_wifi_stage() {
	ssid=$1
	key=$2
	country=$3
	setup_wifi_validate "$ssid" "$key" "$country" || return 1
	country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')
	[ "$country" = "00" ] && country=$FACTORY_WIFI_COUNTRY
	setup_pending_set wifi_ssid "$ssid" || return 1
	setup_pending_set wifi_key "$key" || return 1
	setup_pending_set wifi_country "$country" || return 1
	return 0
}

# uci set (no commit) SSID/key on every AP iface + country on every radio.
# Sets SETUP_WIFI_CC to the regulatory country actually written (C6: 00 →
# factory country; hostapd rejects country_code 00).
setup_wifi_set_uci() {
	ssid=$1
	key=$2
	country=$3
	setup_wifi_validate "$ssid" "$key" "$country" || return 1
	country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')
	case "$country" in
		00|"") country=$FACTORY_WIFI_COUNTRY ;;
	esac
	SETUP_WIFI_CC=$country
	for sec in $(uci -q show wireless | sed -n 's/^\(wireless\.[^=]*\)=wifi-device.*/\1/p'); do
		uci -q set "${sec}.country=$country"
		uci -q set "${sec}.disabled=0"
	done
	# Same SSID/key on every wifi-iface (2.4 + 5 GHz)
	uci -q show wireless | grep -q '=wifi-iface' || return 1
	for iface in $(uci -q show wireless | sed -n 's/^\(wireless\.[^=]*\)=wifi-iface.*/\1/p'); do
		uci -q set "${iface}.ssid=$ssid"
		uci -q set "${iface}.key=$key"
		uci -q set "${iface}.encryption=psk2"
		uci -q set "${iface}.disabled=0"
		uci -q set "${iface}.network=lan"
	done
}

setup_wifi_apply() {
	setup_wifi_set_uci "$1" "$2" "$3" || { uci -q revert wireless 2>/dev/null; return 1; }
	uci commit wireless
	mkdir -p /etc/knots
	printf '%s\n' "$SETUP_WIFI_CC" >/etc/knots/wifi-country
}

# Foreground reload (boot / wifi-default-enable — not a CGI).
setup_wifi_reload_now() {
	wifi reload 2>/dev/null || wifi 2>/dev/null || true
}

# Disconnect every Wi-Fi station so it re-joins (and re-DHCPs) after a LAN
# move; full radio reload only if hostapd's ubus API is unavailable.
setup_wifi_deauth_stations() {
	objs=$(setup_hostapd_objs)
	if [ -z "$objs" ]; then
		wifi reload 2>/dev/null || wifi 2>/dev/null || true
		return 0
	fi
	for obj in $objs; do
		ubus call "$obj" get_clients 2>/dev/null | \
			sed -n 's/^[[:space:]]*"\([0-9a-fA-F:]\{17\}\)":.*/\1/p' | while read -r m; do
			ubus call "$obj" del_client "{\"addr\":\"$m\",\"reason\":5,\"deauth\":true,\"ban_time\":0}" \
				>/dev/null 2>&1 || true
		done
	done
}

setup_netmask_prefix() {
	case "$1" in
		255.255.0.0) echo 16 ;;
		255.255.128.0) echo 17 ;;
		255.255.192.0) echo 18 ;;
		255.255.224.0) echo 19 ;;
		255.255.240.0) echo 20 ;;
		255.255.248.0) echo 21 ;;
		255.255.252.0) echo 22 ;;
		255.255.254.0) echo 23 ;;
		255.255.255.0) echo 24 ;;
		255.255.255.128) echo 25 ;;
		255.255.255.192) echo 26 ;;
		255.255.255.224) echo 27 ;;
		255.255.255.240) echo 28 ;;
		255.255.255.248) echo 29 ;;
		*) return 1 ;;
	esac
}

# Dotted quad → integer. Strict: 4 decimal octets 0-255, no leading zeros
# (01 is octal to some resolvers), nothing else.
setup_ip_to_int() {
	printf '%s' "$1" | grep -qE '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' || return 1
	_old=$IFS; IFS=.
	# shellcheck disable=SC2086
	set -- $1
	IFS=$_old
	for _o in "$1" "$2" "$3" "$4"; do [ "$_o" -le 255 ] || return 1; done
	echo $(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))
}

# C5/N6 (review 2026-10-11): the old check accepted 0.0.0.0, 127/8,
# multicast, the subnet's network/broadcast address, the DMZ (21.21.21.0/24),
# leading-zero octets and DHCP pools outside the subnet or covering the
# router — each strands the appliance. Private (RFC 1918) only: the HTTPS CA
# is name-constrained to private ranges, so a public LAN IP has no valid cert.
setup_lan_validate() {
	ipaddr=$1
	netmask=$2
	dhcp_start=$3
	dhcp_limit=$4
	[ -n "$netmask" ] || netmask=255.255.255.0
	[ -n "$dhcp_start" ] || dhcp_start=100
	[ -n "$dhcp_limit" ] || dhcp_limit=101
	ipn=$(setup_ip_to_int "$ipaddr") || return 1
	pfx=$(setup_netmask_prefix "$netmask") || return 1
	case "$dhcp_start" in ''|*[!0-9]*) return 1 ;; esac
	case "$dhcp_limit" in ''|*[!0-9]*) return 1 ;; esac
	[ "${#dhcp_start}" -le 6 ] && [ "${#dhcp_limit}" -le 6 ] || return 1
	maskn=$(( (0xffffffff << (32 - pfx)) & 0xffffffff ))
	net=$(( ipn & maskn ))
	hosts=$(( 1 << (32 - pfx) ))
	host=$(( ipn - net ))
	# RFC 1918 only
	if [ $(( ipn >> 24 )) -eq 10 ]; then :
	elif [ $(( ipn >> 20 )) -eq $(( (172 << 4) + 1 )) ]; then :
	elif [ $(( ipn >> 16 )) -eq $(( (192 << 8) + 168 )) ]; then :
	else return 1
	fi
	# not the network or broadcast address of its subnet
	[ "$host" -gt 0 ] && [ "$host" -lt $(( hosts - 1 )) ] || return 1
	# must not overlap the appliance DMZ 21.21.21.0/24 (never private, but keep
	# the guard explicit in case the DMZ ever moves)
	dmz=$(setup_ip_to_int 21.21.21.1)
	[ $(( dmz & maskn )) -ne "$net" ] || return 1
	# DHCP pool: offsets [start, start+limit-1] inside the usable hosts and
	# not covering the router's own address
	[ "$dhcp_start" -ge 1 ] && [ "$dhcp_limit" -ge 1 ] || return 1
	last=$(( dhcp_start + dhcp_limit - 1 ))
	[ "$last" -le $(( hosts - 2 )) ] || return 1
	if [ "$host" -ge "$dhcp_start" ] && [ "$host" -le "$last" ]; then
		return 1
	fi
	return 0
}

setup_lan_stage() {
	ipaddr=$1
	netmask=$2
	dhcp_start=$3
	dhcp_limit=$4
	[ -n "$netmask" ] || netmask=255.255.255.0
	[ -n "$dhcp_start" ] || dhcp_start=100
	[ -n "$dhcp_limit" ] || dhcp_limit=101
	setup_lan_validate "$ipaddr" "$netmask" "$dhcp_start" "$dhcp_limit" || return 1
	setup_pending_set lan_ipaddr "$ipaddr" || return 1
	setup_pending_set lan_netmask "$netmask" || return 1
	setup_pending_set lan_dhcp_start "$dhcp_start" || return 1
	setup_pending_set lan_dhcp_limit "$dhcp_limit" || return 1
	return 0
}

setup_node_can_set() {
	impl=$1
	case "$impl" in knots|core) ;; *) return 1 ;; esac
	[ "$(setup_current_impl)" = "$impl" ] && return 0
	grep -q ' /mnt/bitcoin ' /proc/mounts 2>/dev/null || return 2
	[ -x "/mnt/bitcoin/node-bin/$impl/bin/bitcoind" ] && return 0
	return 2
}

setup_node_stage() {
	impl=$1
	setup_node_can_set "$impl" || return $?
	setup_pending_set node_impl "$impl" || return 1
	return 0
}

# Reissue the HTTPS leaf for the current UCI LAN IP. Same CA as IUE (N13).
# Optional extra SAN: second arg = old IP held as alias during cutover.
setup_tls_refresh_lan() {
	[ -x /usr/libexec/knots/node-ui-tls.sh ] || return 0
	if [ -n "$1" ]; then
		KNOTS_LAN_IP="$1" KNOTS_LAN_IP_EXTRA="${2:-}" \
			/usr/libexec/knots/node-ui-tls.sh node-router --leaf || true
	else
		KNOTS_LAN_IP_EXTRA="${2:-}" \
			/usr/libexec/knots/node-ui-tls.sh node-router --leaf || true
	fi
}

# C10/B15: the one implementation reader lives in node-impl-lib.sh.
setup_current_impl() {
	# shellcheck disable=SC1091
	( . /usr/libexec/knots/node-impl-lib.sh && read_impl ) 2>/dev/null || echo core
}

# C1/C2 (review 2026-10-11) — Finish (Guided `complete` and Quick Start) is
# validate-all → apply-together:
#   1. setup_finish_validate checks every staged value (Wi-Fi, LAN, node) and
#      sets SETUP_ERR_CODE / SETUP_ERR_MSG — nothing is changed yet.
#   2. setup_apply_staged_finish `uci set`s LAN/DHCP/Wi-Fi, then commits the
#      three packages together (reverting all on any error). It no longer
#      switches the node in the CGI (minutes of stop/start → 502).
#   3. The cutover worker applies the network, then switches the node LAST.
setup_finish_validate() {
	SETUP_ERR_CODE=
	SETUP_ERR_MSG=
	if setup_wifi_available; then
		if setup_pending_has wifi_key; then
			_wk=$(setup_pending_get wifi_key)
			_ws=$(setup_pending_get wifi_ssid 2>/dev/null || echo rnode)
			_wc=$(setup_pending_get wifi_country 2>/dev/null || echo "$FACTORY_WIFI_COUNTRY")
			setup_wifi_validate "${_ws:-rnode}" "$_wk" "$_wc" || {
				SETUP_ERR_CODE=wifi_failed
				SETUP_ERR_MSG="Wi-Fi settings are invalid (SSID max 32; password 8–63 characters)"
				return 1
			}
		else
			_wk=$(setup_wifi_current_key)
		fi
		if setup_wifi_is_factory_key "$_wk"; then
			SETUP_ERR_CODE=factory_forbidden
			SETUP_ERR_MSG="Choose a new Wi-Fi password — not the factory default"
			return 1
		fi
	fi
	if setup_pending_has lan_ipaddr; then
		setup_lan_validate "$(setup_pending_get lan_ipaddr)" \
			"$(setup_pending_get lan_netmask 2>/dev/null)" \
			"$(setup_pending_get lan_dhcp_start 2>/dev/null)" \
			"$(setup_pending_get lan_dhcp_limit 2>/dev/null)" || {
			SETUP_ERR_CODE=lan_failed
			SETUP_ERR_MSG="LAN settings are invalid — go back to the LAN step"
			return 1
		}
	fi
	if setup_pending_has node_impl; then
		_nrc=0
		setup_node_can_set "$(setup_pending_get node_impl)" || _nrc=$?
		if [ "$_nrc" -ne 0 ]; then
			SETUP_ERR_CODE=node_missing
			SETUP_ERR_MSG="That node is not installed on this appliance (or the M.2 drive is not ready). Keep Bitcoin Core for setup, or install the other node later under Node software."
			return 1
		fi
	fi
	return 0
}

# Prints: old_ip new_ip old_mask wifi_reload lan_cfg_changed dhcp_changed node_target
setup_apply_staged_finish() {
	setup_finish_validate || return 1
	old_ip=$(uci -q get network.lan.ipaddr 2>/dev/null || echo 192.168.1.254)
	old_mask=$(uci -q get network.lan.netmask 2>/dev/null || echo 255.255.255.0)
	old_st=$(uci -q get dhcp.lan.start 2>/dev/null || echo 100)
	old_lim=$(uci -q get dhcp.lan.limit 2>/dev/null || echo 101)
	new_ip=$old_ip
	new_mask=$old_mask
	wifi_reload=0
	lan_cfg=0
	dhcp_chg=0
	node_target=-
	if setup_pending_has lan_ipaddr; then
		new_ip=$(setup_pending_get lan_ipaddr)
		new_mask=$(setup_pending_get lan_netmask 2>/dev/null || echo 255.255.255.0)
		lst=$(setup_pending_get lan_dhcp_start 2>/dev/null || echo 100)
		llim=$(setup_pending_get lan_dhcp_limit 2>/dev/null || echo 101)
		[ -n "$new_mask" ] || new_mask=255.255.255.0
		uci -q set network.lan.proto='static' &&
			uci -q set network.lan.ipaddr="$new_ip" &&
			uci -q set network.lan.netmask="$new_mask" &&
			uci -q set dhcp.lan.start="${lst:-100}" &&
			uci -q set dhcp.lan.limit="${llim:-101}" || { setup_uci_revert; return 1; }
		{ [ "$new_ip" != "$old_ip" ] || [ "$new_mask" != "$old_mask" ]; } && lan_cfg=1
		{ [ "${lst:-100}" != "$old_st" ] || [ "${llim:-101}" != "$old_lim" ]; } && dhcp_chg=1
	fi
	if setup_pending_has wifi_key; then
		wssid=$(setup_pending_get wifi_ssid 2>/dev/null || echo rnode)
		wcc=$(setup_pending_get wifi_country 2>/dev/null || echo "$FACTORY_WIFI_COUNTRY")
		setup_wifi_set_uci "${wssid:-rnode}" "$(setup_pending_get wifi_key)" "$wcc" || { setup_uci_revert; return 1; }
		wifi_reload=1
	fi
	if setup_pending_has node_impl; then
		_t=$(setup_pending_get node_impl)
		[ "$_t" != "$(setup_current_impl)" ] && node_target=$_t
	fi
	# Commit together (validated above, so these do not fail on content).
	uci commit network && uci commit dhcp || { setup_uci_revert; return 1; }
	if [ "$wifi_reload" = 1 ]; then
		uci commit wireless || { setup_uci_revert; return 1; }
	fi
	if [ "$wifi_reload" = 1 ]; then
		mkdir -p "${SETUP_ETC:-/etc/knots}"
		printf '%s\n' "$SETUP_WIFI_CC" >"${SETUP_ETC:-/etc/knots}/wifi-country"
	fi
	if [ "$new_ip" != "$old_ip" ]; then
		# rnode.local tracks the LAN IP (U17/N13; dnsmasq serves .local only
		# from local sources — rfc6761). Two plain patterns: no \| in busybox BRE.
		sed -i -e '/[[:space:]]rnode\.local$/d' -e '/[[:space:]]rnode\.local[[:space:]]/d' "${SETUP_HOSTS_FILE:-/etc/hosts}" 2>/dev/null || true
		echo "$new_ip rnode.local" >>"${SETUP_HOSTS_FILE:-/etc/hosts}"
	fi
	printf '%s %s %s %s %s %s %s' "$old_ip" "$new_ip" "$old_mask" "$wifi_reload" "$lan_cfg" "$dhcp_chg" "$node_target"
}

setup_uci_revert() {
	uci -q revert network 2>/dev/null || true
	uci -q revert dhcp 2>/dev/null || true
	uci -q revert wireless 2>/dev/null || true
}

# One Finish cutover (U17): JSON already returned. setsid so uhttpd does not
# wait; argv0 knots-cutover (factory reset kills an in-flight one).
setup_schedule_cutover() {
	old_ip=$1
	new_ip=$2
	old_mask=$3
	wifi_reload=$4
	lan_cfg=$5
	dhcp_chg=$6
	node_target=${7:--}
	# S7/N17 — values as positional args, never spliced into the script text.
	mkdir -p /tmp/knots
	setsid sh -c '
		. /usr/libexec/knots/setup-lib.sh
		sleep 2
		setup_cutover_now "$@"
	' knots-cutover "$old_ip" "$new_ip" "$old_mask" "$wifi_reload" "$lan_cfg" "$dhcp_chg" "$node_target" \
		</dev/null >>/tmp/knots/setup-cutover.log 2>&1 &
}

# Wait (≤ $2 s) until br-lan carries $1.
setup_wait_lan_ip() {
	_n=0
	while [ "$_n" -lt "${2:-30}" ]; do
		ip -4 addr show dev br-lan 2>/dev/null | grep -q "inet $1/" && return 0
		sleep 1
		_n=$((_n + 1))
	done
	return 1
}

# Temporary rnode.local → old IP during the hold: dnsmasq reads /tmp/hosts
# (addn-hosts) — gone on reboot, unlike the old /etc/hosts line.
SETUP_CUTOVER_HOSTS=/tmp/hosts/knots-cutover

setup_cutover_now() {
	old_ip=$1
	new_ip=$2
	old_mask=$3
	wifi_reload=$4
	lan_cfg=$5
	dhcp_chg=$6
	node_target=${7:--}
	echo "cutover: $*"
	ip_changed=0
	[ -n "$old_ip" ] && [ -n "$new_ip" ] && [ "$old_ip" != "$new_ip" ] && ip_changed=1
	pfx=$(setup_netmask_prefix "$old_mask") || pfx=24
	if [ "$ip_changed" = 1 ]; then
		setup_tls_refresh_lan "$new_ip" "$old_ip"
		ifup lan 2>/dev/null || /etc/init.d/network reload 2>/dev/null || true
		# C3/K4: the alias used to be added before the async ifup finished —
		# EEXIST, or netifd removed it when it applied the new config.
		setup_wait_lan_ip "$new_ip" 30 || echo "cutover: $new_ip not on br-lan after 30 s"
		_a=0
		while [ "$_a" -lt 5 ]; do
			ip addr add "$old_ip/$pfx" dev br-lan 2>/dev/null || true
			sleep 1
			ip -4 addr show dev br-lan | grep -q "inet $old_ip/" && break
			_a=$((_a + 1))
		done
		mkdir -p /tmp/hosts
		echo "$old_ip rnode.local" >"$SETUP_CUTOVER_HOSTS"
		/etc/init.d/dnsmasq reload 2>/dev/null || true
	elif [ "$lan_cfg" = 1 ]; then
		# C3/K2: same IP, new mask — must still reach netifd.
		/etc/init.d/network reload 2>/dev/null || true
		/etc/init.d/dnsmasq reload 2>/dev/null || true
	elif [ "$dhcp_chg" = 1 ]; then
		/etc/init.d/dnsmasq reload 2>/dev/null || true
	fi
	if [ "$wifi_reload" = 1 ]; then
		wifi reload 2>/dev/null || wifi 2>/dev/null || true
	elif [ "$ip_changed" = 1 ]; then
		setup_wifi_deauth_stations
	fi
	# Node switch LAST, under the node-op lock, with a recorded outcome (L2).
	if [ "$node_target" = knots ] || [ "$node_target" = core ]; then
		setup_cutover_node "$node_target"
	fi
	if [ "$ip_changed" = 1 ]; then
		sleep 120
		ip addr del "$old_ip/$pfx" dev br-lan 2>/dev/null || true
		rm -f "$SETUP_CUTOVER_HOSTS"
		setup_tls_refresh_lan "$new_ip"
		/etc/init.d/dnsmasq reload 2>/dev/null || true
	fi
	echo "cutover: done"
}

setup_cutover_node() {
	# shellcheck disable=SC1091
	. /usr/libexec/knots/node-impl-lib.sh
	_w=0
	while ! node_op_acquire set "Setup: switching to ${1}"; do
		_w=$((_w + 5))
		[ "$_w" -lt 600 ] || { node_op_result set failed "Setup could not switch the node (another node operation was running) — use Node software"; return 1; }
		sleep 5
	done
	node_op_result set running "In progress"
	if setup_node_set "$1"; then
		node_op_result set ok "Now running ${1}."
	else
		node_op_result set failed "Setup could not switch to ${1}; the previous node was kept — see Node software"
	fi
	node_op_release
}

setup_node_set() {
	impl=$1
	case "$impl" in knots|core) ;; *) return 1 ;; esac
	# U17 first-run has no wallet UX (Phase 2); leftover lab wallet dirs on the
	# shared datadir must not block Knots/Core choice. Pass WALLET_ACK here only.
	# Post-Setup Node software still requires explicit UI ack (U7a).
	/usr/libexec/knots/node-impl.sh set "$impl" SWITCH WALLET_ACK
}

UI_LANG_FILE=/etc/knots/ui-lang
REGIONS_JSON=/www/knots/i18n/regions.json

setup_locale_done() {
	[ -f "$SETUP_LOCALE_DONE" ]
}

setup_mark_locale_done() {
	mkdir -p /etc/knots
	: >"$SETUP_LOCALE_DONE"
}

setup_ui_lang() {
	if [ -f "$UI_LANG_FILE" ]; then
		tr -d '\r\n' <"$UI_LANG_FILE"
	else
		echo en
	fi
}

# Map Knots ui-lang → LuCI luci.main.lang
setup_luci_lang_for() {
	case "$1" in
		es) echo es ;;
		de) echo de ;;
		fr) echo fr ;;
		zh-cn) echo zh_cn ;;
		ja) echo ja ;;
		pt-br) echo pt_br ;;
		*) echo en ;;
	esac
}

# Language only — Knots UI + LuCI (Setup + Settings U19). Does not change timezone.
setup_ui_lang_apply() {
	lang=$1
	case "$lang" in
		en|es|de|fr|zh-cn|ja|pt-br) ;;
		*) return 1 ;;
	esac
	mkdir -p /etc/knots
	printf '%s\n' "$lang" >"$UI_LANG_FILE"
	cp -f "$UI_LANG_FILE" /www/knots/ui-lang 2>/dev/null || true
	luci_lang=$(setup_luci_lang_for "$lang")
	if uci -q get luci.main >/dev/null 2>&1; then
		uci -q set luci.main.lang="$luci_lang"
		uci -q commit luci
	fi
	return 0
}

# Lookup catalog fields from regions.json (match on cc or zonename)
setup_region_lookup() {
	match_field=$1
	match_val=$2
	out_field=$3
	[ -n "$match_field" ] && [ -n "$match_val" ] && [ -f "$REGIONS_JSON" ] || return 1
	awk -v mf="$match_field" -v mv="$match_val" -v of="$out_field" '
		BEGIN { found = 0 }
		{
			patm = "\"" mf "\"[[:space:]]*:[[:space:]]*\"" mv "\""
			if ($0 ~ patm) {
				pato = "\"" of "\"[[:space:]]*:[[:space:]]*\"([^\"]+)\""
				if (match($0, pato)) {
					s = substr($0, RSTART, RLENGTH)
					sub(/^[^"]*"[^"]*"[[:space:]]*:[[:space:]]*"/, "", s)
					sub(/"$/, "", s)
					print s
					exit
				}
			}
		}
	' "$REGIONS_JSON"
}

# Apply UI language + router timezone (UCI system + /etc/localtime) + Wi‑Fi country.
# Primary: zonename (IANA). country optional if derivable from catalog.
setup_locale_apply() {
	lang=$1
	country=$2
	zonename=$3
	# C1 (review 2026-10-11): validate everything before changing anything —
	# the language used to be applied even when the zone was then rejected.
	case "$lang" in
		en|es|de|fr|zh-cn|ja|pt-br) ;;
		*) return 1 ;;
	esac

	# Country, when provided, must be exactly 2 letters (normalized below)
	if [ -n "$country" ]; then
		case "$country" in
			[A-Za-z][A-Za-z]) ;;
			*) return 1 ;;
		esac
	fi

	if [ -z "$zonename" ] && [ -n "$country" ]; then
		country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')
		zonename=$(setup_region_lookup cc "$country" zonename) || true
	fi
	[ -n "$zonename" ] || return 1
	# M4 — zonename becomes a filesystem path: strict IANA charset, no traversal.
	# {0,2} also allows single-component zones (UTC, GMT, CET, …)
	case "$zonename" in
		*..*) return 1 ;;
	esac
	printf '%s' "$zonename" | grep -qE '^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+){0,2}$' || return 1

	if [ -z "$country" ]; then
		country=$(setup_region_lookup zonename "$zonename" cc) || true
	fi
	# Zones outside the catalog (e.g. UTC) map to no country: fall back to the
	# world regulatory domain (00) instead of rejecting a valid IANA zone.
	[ -n "$country" ] || country=00
	country=$(printf '%s' "$country" | tr 'a-z' 'A-Z')
	case "$country" in
		00|[A-Z][A-Z]) ;;
		*) return 1 ;;
	esac

	tz=$(setup_region_lookup zonename "$zonename" timezone) || true
	if [ -z "$tz" ]; then
		tz=$(setup_region_lookup cc "$country" timezone) || true
	fi
	[ -n "$tz" ] || tz=UTC
	[ "${SETUP_LOCALE_CHECK_ONLY:-0}" = 1 ] && return 0

	setup_ui_lang_apply "$lang" || return 1

	uci -q set system.@system[0].zonename="$zonename"
	uci -q set system.@system[0].timezone="$tz"
	uci -q commit system
	# Prefer zoneinfo file when present (sets the router clock display)
	if [ -f "/usr/share/zoneinfo/$zonename" ]; then
		ln -sf "/usr/share/zoneinfo/$zonename" /etc/localtime 2>/dev/null || true
	elif [ -f "/usr/share/zoneinfo/Etc/UTC" ] && [ "$zonename" = "UTC" ]; then
		ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime 2>/dev/null || true
	fi
	/etc/init.d/system reload >/dev/null 2>&1 || true

	# Remember Wi-Fi country for the Wi-Fi step (and apply if radio already configured)
	# C6/N8: 00 (zones outside the catalog, e.g. UTC) is the world domain —
	# hostapd rejects country_code 00, which left the AP dead after a reboot
	# before Finish. Radios get the factory country instead.
	radio_cc=$country
	[ "$radio_cc" = 00 ] && radio_cc=$FACTORY_WIFI_COUNTRY
	mkdir -p /etc/knots
	printf '%s\n' "$radio_cc" >/etc/knots/wifi-country
	if setup_wifi_available; then
		for sec in $(uci -q show wireless 2>/dev/null | sed -n 's/^\(wireless\.[^=]*\)=wifi-device.*/\1/p'); do
			uci -q set "${sec}.country=$radio_cc"
		done
		uci -q commit wireless
	fi

	setup_mark_locale_done
	return 0
}
