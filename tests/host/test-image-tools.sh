#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-IMAGE-TOOLS — 2026-10-18 UAT-NB found node-impl.sh used `od`, which the
# router image does not have: every official Knots/Core tarball install was
# refused on hardware while host tests passed with the workstation's GNU od.
#  1. static: firmware scripts never call commands the image lacks (od, xxd,
#     base64, timeout, …) — always runs
#  2. device: is_aarch64_elf() run by the IMAGE's own BusyBox in a chroot
#     accepts the real bitcoind from the pinned tarball and refuses an x86-64
#     ELF and a text file — needs the Image Builder rootfs, docker and the
#     qemu-aarch64 binfmt (distro package qemu-user-static); else SKIP.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
RFS="$ROOT/build/imagebuilder/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# 1. static — commands verified absent from the .95 image rootfs (no applet link)
MISSING_ON_IMAGE="od xxd base64 timeout realpath tac shuf column numfmt nl comm stat hostapd_cli nmcli"
bad=""
for f in "$K"/*.sh "$K"/factory/*.sh "$ROOT"/files/etc/init.d/* "$ROOT"/files/etc/uci-defaults/* \
	"$ROOT"/files/etc/hotplug.d/*/* "$ROOT"/files/usr/sbin/* "$ROOT"/files/etc/rc.button/*; do
	[ -f "$f" ] || continue
	for c in $MISSING_ON_IMAGE; do
		# a command word: line start or after | ; & ( $( `  — not in comments
		if grep -vE '^[[:space:]]*#' "$f" | grep -qE "(^|[|;&(\`]|\\\$\\()[[:space:]]*$c([[:space:]]|\$)"; then
			bad="$bad ${f#$ROOT/}:$c"
		fi
	done
done
[ -z "$bad" ] || fail "firmware calls commands missing on the router image:$bad"
pass "no firmware script calls a command the image lacks ($MISSING_ON_IMAGE)"

# 2. device — real BusyBox from the image
skip() { echo "SKIP device part: $*"; echo "ALL PASS: test-image-tools (T-IMAGE-TOOLS, static only)"; exit 0; }
[ -x "$RFS/bin/busybox" ] || skip "no Image Builder rootfs (run make image)"
command -v docker >/dev/null 2>&1 || skip "docker not installed"
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || skip "no qemu-aarch64 binfmt (sudo apt install qemu-user-binfmt (older releases: qemu-user-static binfmt-support))"
docker image inspect alpine:3.20 >/dev/null 2>&1 || skip "alpine:3.20 image not present"
TGZ="$ROOT/build/dl/bitcoin-29.4-aarch64-linux-gnu.tar.gz"
[ -f "$TGZ" ] || skip "pinned Core tarball not in build/dl"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
tar -xzf "$TGZ" -C "$W" --wildcards '*/bin/bitcoind' --strip-components=2
cp /bin/ls "$W/x86elf"
echo "not a binary" >"$W/text"
awk '/^is_aarch64_elf\(\)/,/^}/' "$K/node-impl.sh" >"$W/fn.sh"
cat >"$W/t.sh" <<'EOF'
. /mnt/fn.sh
is_aarch64_elf /mnt/bitcoind && echo "bitcoind=yes" || echo "bitcoind=no"
is_aarch64_elf /mnt/x86elf && echo "x86=yes" || echo "x86=no"
is_aarch64_elf /mnt/text && echo "text=yes" || echo "text=no"
EOF
# The image rootfs has an empty, read-only /dev: give the chroot a small
# writable /dev with a null device (the function redirects to /dev/null).
out=$(docker run --rm -v "$RFS":/rootfs:ro -v "$W":/rootfs/mnt --tmpfs /rootfs/dev:rw,dev,size=64k alpine:3.20 \
	sh -c 'mknod -m 666 /rootfs/dev/null c 1 3 && chroot /rootfs /bin/busybox sh /mnt/t.sh' 2>&1) || fail "image busybox run: $out"
echo "$out" | grep -qx 'bitcoind=yes' || fail "official aarch64 bitcoind refused by the image's shell: $out"
echo "$out" | grep -qx 'x86=no' && echo "$out" | grep -qx 'text=no' || fail "non-aarch64 files accepted: $out"
pass "is_aarch64_elf on the image's BusyBox: official bitcoind accepted, x86-64 / text refused"
echo "ALL PASS: test-image-tools (T-IMAGE-TOOLS)"
