#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-UHTTPD-DEVICE — the IMAGE's own uhttpd (mbedTLS) must start with the TLS
# files the overlay configures for LuCI :8443. .83 shipped a P3 CA with
# critical nameConstraints inside fullchain.pem and LuCI crash-looped
# ("Failed to load certificate/key files"); host tools never saw it.
# Runs node-ui-tls.sh to make real certs, then the image uhttpd under qemu in a
# throwaway container (writable rootfs copy, host /dev nodes bound).
# SKIPs when no image rootfs / docker / aarch64 binfmt.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RFS="$ROOT/build/imagebuilder/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP T-UHTTPD-DEVICE: $*"; exit 0; }
[ -x "$RFS/usr/sbin/uhttpd" ] || skip "no Image Builder rootfs (run make image)"
command -v docker >/dev/null 2>&1 || skip "docker not installed"
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || skip "no qemu-aarch64 binfmt"
docker image inspect alpine:3.20 >/dev/null 2>&1 || skip "alpine:3.20 image not present"
command -v openssl >/dev/null 2>&1 || skip "no openssl"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/rootfs"
tar -C "$RFS" --exclude=./srv/lxc --exclude=./www -cf - . | tar -C "$W/rootfs" -xf - 2>/dev/null
mkdir -p "$W/rootfs/mnt/www" && echo ok >"$W/rootfs/mnt/www/index.html"
KNOTS_TLS_DIR="$W/rootfs/mnt/tls" KNOTS_WWW_DIR="$W/pub" KNOTS_LAN_IP=192.168.1.254 \
	sh "$ROOT/files/usr/libexec/knots/node-ui-tls.sh" node-router >/dev/null 2>&1 || fail "node-ui-tls.sh"
# Which file does the overlay give uhttpd? (ui-ports.sh is authoritative at boot)
cert=$(sed -n "s|.*uhttpd.main.cert='/etc/knots/tls/\([a-z]*\.pem\)'.*|\1|p" "$ROOT/files/usr/libexec/knots/ui-ports.sh" | head -1)
[ -n "$cert" ] || fail "cannot find uhttpd.main.cert in ui-ports.sh"

up() { # CERTFILE → RUNNING / EXITED + log
	docker run --rm -v "$W/rootfs":/rootfs -v /dev/null:/rootfs/dev/null \
		-v /dev/urandom:/rootfs/dev/urandom -v /dev/random:/rootfs/dev/random alpine:3.20 \
		chroot /rootfs sh -c "uhttpd -f -h /mnt/www -s 127.0.0.1:18443 -C /mnt/tls/$1 -K /mnt/tls/key.pem >/mnt/u.log 2>&1 & p=\$!; sleep 4; if kill -0 \$p 2>/dev/null; then echo RUNNING; kill \$p; else echo EXITED; cat /mnt/u.log; fi"
}
out=$(up "$cert")
case "$out" in RUNNING*) ;; *) fail "image uhttpd does not start with $cert: $out" ;; esac
# Guard the reason: the constrained CA in a chain is what mbedTLS rejects.
out=$(up fullchain.pem)
case "$out" in *"Failed to load certificate"*) ;; *) echo "NOTE: image uhttpd now accepts fullchain.pem ($out)" ;; esac
echo "PASS T-UHTTPD-DEVICE (image uhttpd starts with $cert + constrained CA)"
