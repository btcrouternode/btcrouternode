#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# First-use "Sign in to network" (owner request 2026-10-24): while Setup is NOT
# complete, the router answers phones' / laptops' connectivity checks itself, so
# the OS shows its captive-portal window and opens Setup on its own — and stops
# ignoring a Wi-Fi network that has no internet yet (Android otherwise sends the
# browser over mobile data). nginx turns those requests into a redirect to
# Setup (knots-ui.conf, $knots_captive). The moment Setup completes (or on any
# boot after it) the DNS entries are removed: customers never see it again.
#
#   captive-portal.sh sync   on while Setup is incomplete, off once complete
#   captive-portal.sh on|off|status
set -u
COMPLETE="${KNOTS_SETUP_COMPLETE:-/etc/knots/setup-complete}"
# The check names resolve to a PUBLIC test address (RFC 5737), not the LAN IP:
# newer Android stops captive-portal detection and reports "no internet" when a
# check name resolves to a private address (NetworkMonitor
# DNS_PROBE_PRIVATE_IP_NO_INTERNET — Moto g57 / Android 16 on .104). nftables
# sends LAN clients' port-80 traffic for that address to this router's web
# server (redirect to Setup) and refuses everything else to it at once.
PORTAL_IP="${KNOTS_CAPTIVE_IP:-192.0.2.1}"
NFT_TABLE=knots_captive
# Connectivity-check names: Android / Samsung / ChromeOS, Apple, Windows,
# Firefox, GNOME NetworkManager / Ubuntu.
HOSTS="connectivitycheck.gstatic.com connectivitycheck.android.com clients3.google.com
www.google.com play.googleapis.com captive.apple.com www.apple.com www.appleiphonecell.com
www.msftconnecttest.com www.msftncsi.com detectportal.firefox.com nmcheck.gnome.org
connectivity-check.ubuntu.com"

ours() { # the address list entries this script owns: /host/ip
	for a in $(uci -q get dhcp.@dnsmasq[0].address 2>/dev/null); do
		h=$(echo "$a" | cut -d/ -f2)
		for x in $HOSTS; do [ "$h" = "$x" ] && echo "$a"; done
	done
}

nft_on() { # LANIP
	command -v nft >/dev/null 2>&1 || return 0
	nft delete table ip "$NFT_TABLE" 2>/dev/null
	nft -f - <<EOF
table ip $NFT_TABLE {
	chain pre {
		type nat hook prerouting priority dstnat - 5; policy accept;
		iifname "br-lan" ip daddr $PORTAL_IP tcp dport 80 dnat to $1:80
	}
	chain refuse {
		type filter hook forward priority filter - 5; policy accept;
		iifname "br-lan" ip daddr $PORTAL_IP meta l4proto tcp reject with tcp reset
		iifname "br-lan" ip daddr $PORTAL_IP reject
	}
}
EOF
}

nft_off() {
	command -v nft >/dev/null 2>&1 || return 0
	nft delete table ip "$NFT_TABLE" 2>/dev/null || true
}

apply() { # on|off
	ip=$(uci -q get network.lan.ipaddr)
	changed=0
	for a in $(ours); do
		if [ "$1" = off ] || [ "$a" != "/$(echo "$a" | cut -d/ -f2)/$PORTAL_IP" ]; then
			uci -q del_list dhcp.@dnsmasq[0].address="$a"; changed=1
		fi
	done
	if [ "$1" = on ] && [ -n "$ip" ]; then
		have=" $(ours | tr '\n' ' ') "
		for h in $HOSTS; do
			case "$have" in *" /$h/$PORTAL_IP "*) ;; *) uci add_list dhcp.@dnsmasq[0].address="/$h/$PORTAL_IP"; changed=1 ;; esac
		done
		nft_on "$ip"            # always (re)made: follows a LAN IP change, lost on reboot
	else
		nft_off
	fi
	if [ "$changed" = 1 ]; then
		uci commit dhcp
		# RESTART, not reload: dnsmasq's reload is a SIGHUP, which re-reads hosts
		# files but not address= entries — on .104 the portal was "on" in uci
		# while dnsmasq kept answering REFUSED (no internet) for the check names.
		/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
		logger -t knots-captive "captive portal $1 (lan $ip, portal $PORTAL_IP)" 2>/dev/null || true
	fi
}

case "${1:-sync}" in
	sync) if [ -f "$COMPLETE" ]; then apply off; else apply on; fi ;;
	on) apply on ;;
	off) apply off ;;
	status) [ -n "$(ours)" ] && echo on || echo off ;;
	*) echo "usage: captive-portal.sh sync|on|off|status" >&2; exit 2 ;;
esac
exit 0
