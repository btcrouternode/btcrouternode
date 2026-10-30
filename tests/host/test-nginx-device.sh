#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NGX-DEVICE — run the IMAGE's own aarch64 nginx (`nginx -t`) on the overlay
# config, via the Image Builder rootfs + qemu binfmt in a throwaway container.
# Host nginx differs from the router's (e.g. host rounds map_hash_bucket_size up
# to a 64-byte cache line; the router uses 32) — .77 shipped a config that
# passed host nginx -t but did not start on the router.
# SKIPs (exit 0) when the image rootfs, docker or aarch64 binfmt is absent.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
RFS="$ROOT/build/imagebuilder/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
CONF="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
fail() { echo "FAIL: $*" >&2; exit 1; }
skip() { echo "SKIP T-NGX-DEVICE: $*"; exit 0; }

[ -x "$RFS/usr/sbin/nginx" ] || skip "no Image Builder rootfs (run make image)"
command -v docker >/dev/null 2>&1 || skip "docker not installed"
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || skip "no qemu-aarch64 binfmt"
docker image inspect alpine:3.20 >/dev/null 2>&1 || skip "alpine:3.20 image not present"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/body" "$W/proxy" "$W/fastcgi" "$W/uwsgi" "$W/scgi" "$W/logs"
openssl req -x509 -newkey rsa:2048 -keyout "$W/key.pem" -out "$W/fullchain.pem" \
	-days 1 -nodes -subj /CN=rnode.local >/dev/null 2>&1 || fail "openssl"
cp "$ROOT/files/etc/nginx/knots-headers.inc" "$W/headers.inc"
# Realistic (seen on .254) + longest possible IPv6 LAN keys from the hotplug.
printf '"fdd4:d03a:fa17::1" 1;\n"2001:db8:1:2::1" 1;\n"ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff" 1;\n' >"$W/lan.map"
sed -e 's|/etc/nginx/knots-headers.inc|/mnt/headers.inc|g' \
	-e 's|/etc/knots/nginx-lan-addrs.map|/mnt/lan.map|g' \
	-e 's|/etc/knots/tls/fullchain.pem|/mnt/fullchain.pem|g' \
	-e 's|/etc/knots/tls/key.pem|/mnt/key.pem|g' \
	-e 's/listen 80 /listen 3080 /; s/listen \[::\]:80 /listen [::]:3080 /' \
	-e 's/listen 443 /listen 3443 /; s/listen \[::\]:443 /listen [::]:3443 /' \
	-e 's/listen 8080 /listen 38080 /; s/listen \[::\]:8080 /listen [::]:38080 /' \
	"$CONF" >"$W/knots-ui.conf"
cat >"$W/nginx.conf" <<'N'
pid /mnt/nginx.pid;
error_log /mnt/logs/error.log;
events { worker_connections 32; }
http {
  access_log off;
  client_body_temp_path /mnt/body; proxy_temp_path /mnt/proxy;
  fastcgi_temp_path /mnt/fastcgi; uwsgi_temp_path /mnt/uwsgi; scgi_temp_path /mnt/scgi;
  include /mnt/knots-ui.conf;
}
N
out=$(docker run --rm -v "$RFS":/rootfs:ro -v "$W":/rootfs/mnt alpine:3.20 \
	chroot /rootfs /usr/sbin/nginx -t -p /mnt -c /mnt/nginx.conf 2>&1) || {
	echo "$out" >&2
	fail "image nginx -t rejects the overlay config (router nginx would not start)"
}
echo "$out" | grep -q 'test is successful' || { echo "$out" >&2; fail "image nginx -t did not succeed"; }
echo "PASS T-NGX-DEVICE (image nginx $(docker run --rm -v "$RFS":/rootfs:ro alpine:3.20 chroot /rootfs /usr/sbin/nginx -v 2>&1 | sed 's/.*nginx\///'))"
