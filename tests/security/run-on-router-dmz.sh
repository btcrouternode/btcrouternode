#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T5 / NF10 — run ON the appliance (ash): UCI assertions + DMZ→LAN stress.
# Copy to router or: ssh root@192.168.1.254 'sh -s' < run-on-router-dmz.sh
# Optional: LAN_TARGET=192.168.1.100 (a real LAN client IP to prove DMZ↛LAN)

set -e

LAN_NET_PREFIX="${LAN_NET_PREFIX:-192.168.1}"
LAN_GW="${LAN_GW:-192.168.1.254}"
LAN_TARGET="${LAN_TARGET:-}"
STRESS_ROUNDS="${STRESS_ROUNDS:-5}"
pass=0
fail=0

ok() { echo "PASS [DMZ/UCI] $*"; pass=$((pass + 1)); }
bad() { echo "FAIL [DMZ/UCI] $*"; fail=$((fail + 1)); }

echo "=== T5 on-router UCI + DMZ isolation ==="

# --- UCI: no dmz→lan or wan→lan forwarding ---
fwd=$(uci -q show firewall | grep '=forwarding' || true)
echo "$fwd" | grep -q "src='dmz'.*dest='lan'\|src=\"dmz\".*dest=\"lan\"" && \
	bad "firewall has dmz→lan forwarding" || ok "no dmz→lan forwarding section"

# wan→lan unsolicited forward should not exist as a forwarding section
echo "$fwd" | grep "src='wan'" | grep -q "dest='lan'" && \
	bad "firewall has wan→lan forwarding" || ok "no wan→lan forwarding section"

# dmz→wan is expected (N7)
echo "$fwd" | grep -q "dmz_wan\|src='dmz'" && ok "dmz egress path present" || \
	bad "missing dmz→wan forwarding"

# WAN DNAT 8333
dport=$(uci -q get firewall.knots_p2p_dnat.dest_port 2>/dev/null || true)
dip=$(uci -q get firewall.knots_p2p_dnat.dest_ip 2>/dev/null || true)
[ "$dport" = "8333" ] && [ "$dip" = "21.21.21.21" ] && \
	ok "WAN DNAT 8333 → 21.21.21.21" || bad "WAN DNAT 8333 misconfigured ($dport/$dip)"

# WAN reject UI/SSH/RPC
uci -q get firewall.reject_wan_luci.dest_port >/dev/null && ok "reject WAN UI rule present" || \
	bad "missing reject_wan_luci"
uci -q get firewall.reject_wan_ssh.name >/dev/null && ok "reject WAN SSH present" || \
	bad "missing reject_wan_ssh"
# M16 — a missing section must FAIL, not default to "enabled"
en=$(uci -q get firewall.reject_wan_rpc.enabled 2>/dev/null) || en=""
if [ "$en" = "1" ] || [ "$en" = "true" ]; then
	ok "reject WAN RPC enabled"
else
	bad "reject_wan_rpc missing or disabled (enabled='${en:-absent}')"
fi

# External LAN RPC must stay off for Phase 2 default
ext=$(uci -q get firewall.knots_ext_rpc.enabled 2>/dev/null || echo 0)
[ "$ext" = "0" ] || [ "$ext" = "false" ] || [ -z "$ext" ] && \
	ok "LAN→DMZ RPC disabled by default" || bad "LAN→DMZ RPC enabled (Phase 2 default is off)"

upnp=$(uci -q get upnpd.config.enabled 2>/dev/null || echo 0)
[ "$upnp" = "0" ] || [ "$upnp" = "false" ] && ok "UPnP off" || bad "UPnP enabled"

# DMZ zone forward REJECT
zf=$(uci -q get firewall.dmz.forward 2>/dev/null || true)
[ "$zf" = "REJECT" ] && ok "dmz.forward=REJECT" || bad "dmz.forward=$zf (want REJECT)"

# --- DMZ → LAN stress from inside Knots LXC ---
# M16 — a connect-failure to a DEAD host proves nothing. Only probes against
# hosts verified alive from the router LAN side count as PASS; dead hosts SKIP.
if ! command -v lxc-attach >/dev/null 2>&1; then
	bad "lxc-attach missing — cannot DMZ probe"
else
	dmz_probe() { # <ip> — returns 0 if the DMZ opened :80 or :443 in any round
		i=1
		while [ "$i" -le "$STRESS_ROUNDS" ]; do
			if lxc-attach -n knots -- timeout 2 bash -c "echo >/dev/tcp/${1}/80" 2>/dev/null || \
				lxc-attach -n knots -- timeout 2 bash -c "echo >/dev/tcp/${1}/443" 2>/dev/null; then
				return 0
			fi
			i=$((i + 1))
		done
		return 1
	}
	lan_alive() { ping -c1 -W2 "$1" >/dev/null 2>&1; }

	# REQUIRED probe 1: the LAN gateway (always live — the router itself).
	if dmz_probe "$LAN_GW"; then
		bad "DMZ reached LAN gateway $LAN_GW:80/443"
	else
		ok "DMZ cannot open LAN gateway $LAN_GW:80/443 (${STRESS_ROUNDS}x)"
	fi

	# REQUIRED probe 2 when given: an operator-named live LAN client.
	if [ -n "$LAN_TARGET" ]; then
		if lan_alive "$LAN_TARGET"; then
			if dmz_probe "$LAN_TARGET"; then
				bad "DMZ reached live LAN host $LAN_TARGET:80/443"
			else
				ok "DMZ cannot open live LAN host $LAN_TARGET:80/443 (${STRESS_ROUNDS}x)"
			fi
		else
			bad "LAN_TARGET=$LAN_TARGET is not alive from the router — pass a live LAN client IP"
		fi
	else
		echo "WARN [DMZ] LAN_TARGET unset — gateway-only proof; set LAN_TARGET=<live LAN client> for full coverage"
	fi

	# Speculative DHCP-pool addresses: count only if a host answers on LAN.
	for tip in "${LAN_NET_PREFIX}.100" "${LAN_NET_PREFIX}.101" "${LAN_NET_PREFIX}.50"; do
		if ! lan_alive "$tip"; then
			echo "SKIP [DMZ] $tip — no live host (connect-failure would prove nothing)"
			continue
		fi
		if dmz_probe "$tip"; then
			bad "DMZ reached LAN host $tip:80/443"
		else
			ok "DMZ cannot open live host $tip:80/443 (${STRESS_ROUNDS}x)"
		fi
	done

	# DMZ should still reach WAN DNS-ish (egress) — soft check
	if lxc-attach -n knots -- /bin/sh -c "ping -c1 -W2 1.1.1.1 >/dev/null 2>&1"; then
		ok "DMZ egress ping 1.1.1.1 (N7 allow-any)"
	else
		echo "WARN [DMZ] no ping to 1.1.1.1 (WAN down or ICMP filtered) — not FAIL"
	fi
fi

echo "=== on-router result: pass=$pass fail=$fail ==="
[ "$fail" -eq 0 ]
