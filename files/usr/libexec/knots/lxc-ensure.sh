#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Ensure br-dmz and LXC container config/rootfs are ready.

set -e

log() { logger -t knots-lxc "$*"; echo "knots-lxc: $*" >&2; }

LXC_PATH=/srv/lxc/knots
ROOTFS="$LXC_PATH/rootfs"
CONFIG="$LXC_PATH/config"

attach_knots_veth() {
	command -v ip >/dev/null 2>&1 || return 0
	ip link show br-dmz >/dev/null 2>&1 || return 0

	veth=$(lxc-info -n knots 2>/dev/null | awk '/^Link:/{print $2; exit}')
	[ -n "$veth" ] || return 0

	if ! ip -o link show "$veth" 2>/dev/null | grep -q 'master br-dmz'; then
		ip link set "$veth" master br-dmz 2>/dev/null || true
		ip link set "$veth" up 2>/dev/null || true
		log "attached $veth to br-dmz"
	fi
}

case "${1:-}" in
	attach-veth)
		attach_knots_veth
		exit 0
		;;
esac

# Bring up DMZ bridge address if UCI not applied yet
if command -v ip >/dev/null 2>&1; then
	if ! ip link show br-dmz >/dev/null 2>&1; then
		ip link add name br-dmz type bridge 2>/dev/null || true
		ip link set br-dmz up 2>/dev/null || true
	fi
	ip addr add 21.21.21.1/24 dev br-dmz 2>/dev/null || true
	ip -6 addr add fd21:21:21::1/64 dev br-dmz 2>/dev/null || true
	ip link set br-dmz up 2>/dev/null || true
fi

# Host-side -x/-e follow absolute symlinks into the *host* root and fail even when
# the container rootfs is fine (bitcoind -> /usr/local/lib/bitcoin/.../bitcoind).
bitcoind_present() {
	[ -x "$ROOTFS/usr/local/lib/bitcoin/knots/bin/bitcoind" ] && return 0
	[ -x "$ROOTFS/usr/local/lib/bitcoin/core/bin/bitcoind" ] && return 0
	[ -L "$ROOTFS/usr/local/bin/bitcoind" ] && return 0
	[ -f "$ROOTFS/usr/local/bin/bitcoind" ] && return 0
	# B15: runtime binaries may live on M.2 only
	[ -x /mnt/bitcoin/node-bin/knots/bin/bitcoind ] && return 0
	[ -x /mnt/bitcoin/node-bin/core/bin/bitcoind ] && return 0
	return 1
}

if [ ! -d "$ROOTFS/usr" ] || ! bitcoind_present; then
	# Allow compressed rootfs drop-in (busybox tar has no --zstd: pipe via zstd)
	if [ -f /srv/lxc/knots-rootfs-arm64.tar.zst ]; then
		log "extracting rootfs archive"
		mkdir -p "$ROOTFS"
		zstd -dc /srv/lxc/knots-rootfs-arm64.tar.zst | tar -C "$ROOTFS" -xf -
	elif [ ! -d "$ROOTFS/usr" ]; then
		log "LXC rootfs missing"
		exit 1
	fi
fi

mkdir -p "$LXC_PATH" /var/lib/lxc
if [ -f /etc/knots/lxc-config.in ]; then
	cp /etc/knots/lxc-config.in "$CONFIG"
elif [ -f "$LXC_PATH/config.in" ]; then
	cp "$LXC_PATH/config.in" "$CONFIG"
fi

# OpenWrt lxc often expects /var/lib/lxc/<name>
if [ ! -e /var/lib/lxc/knots ]; then
	ln -sfn "$LXC_PATH" /var/lib/lxc/knots 2>/dev/null || true
fi

bitcoind_present || {
	log "bitcoind missing in rootfs"
	exit 1
}
log "lxc rootfs ready"
exit 0
