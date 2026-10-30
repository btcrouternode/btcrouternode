#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Sign the staged release in one go on the offline laptop (live USB): refuses
# while the laptop is online, then runs rnode-offline.sh choice 2 (checks the
# tools + release fingerprints, finds key stick A, signs, verifies like the
# router), then writes everything to the drive. Part of the fingerprinted tool
# set — so start it only AFTER Ubuntu's own sha256sum has checked the tools:
#
#   sudo bash -c 'mount /dev/sdb2 /mnt && cd /mnt/home/pmark/rnode-sign/rnode-keygen && sha256sum SHA256SUMS && sha256sum -c --quiet SHA256SUMS && bash sign-release.sh'
#
# (factory/OFFLINE-KEYGEN.md, "One line".)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
say() { printf '\n== %s\n' "$*"; }
stop() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || [ -n "${RNODE_OFFLINE_TEST:-}" ] || stop "run it with sudo (see the line at the top of this file)"

# --- offline? -----------------------------------------------------------------
online_reasons() {
	if [ -n "${RNODE_OFFLINE_FAKE_ONLINE:-}" ]; then echo "test: pretend online"; return; fi
	[ -n "${RNODE_OFFLINE_TEST:-}" ] && return
	ip route show default 2>/dev/null | grep -q . && echo "a default route (network connection): $(ip route show default | head -1)"
	ip -6 route show default 2>/dev/null | grep -q . && echo "an IPv6 default route"
	ip -o addr show scope global 2>/dev/null | awk '{print "an address on " $2 ": " $4}'
	return 0
}
reasons=$(online_reasons)
if [ -n "$reasons" ]; then
	printf '%s\n' "$reasons" | sed 's/^/  - /' >&2
	stop "this laptop is ONLINE. Turn Wi-Fi off, unplug the network cable (also the one to the router), then run the line again."
fi
if command -v rfkill >/dev/null 2>&1 && [ -z "${RNODE_OFFLINE_TEST:-}" ]; then
	if rfkill list 2>/dev/null | awk '/Wireless LAN|Bluetooth/{t=$0} /Soft blocked: no/{if(t) print t}' | grep -q .; then
		echo "Note: Wi-Fi or Bluetooth is still switched on (not connected). Switching it off is safer."
	fi
fi
say "Offline: no network connection."

# --- sign -----------------------------------------------------------------------
bash "$HERE/rnode-offline.sh" 2

sync
say "Done. Write down the signed fingerprint shown above."
echo "  Then shut down (the drive is written), remove the live USB, reconnect the"
echo "  network and start the laptop normally — the build PC collects signed/."
