#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-CONSOLE-LOGIN — the serial console asks for the router password (owner
# decision 2026-10-22; OpenWrt default is a password-less root shell).
#  - uci-defaults sets system.@system[0].ttylogin=1 and commits (stub uci)
#  - the image's own login.sh / inittab honour it (Image Builder rootfs)
#  - the root password is always set on first boot (92-knots-password)
#  - only the production script logs in on the console (to install the
#    factory station's ssh key, removed again before the unit ships)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
UD="$ROOT/files/etc/uci-defaults/88-knots-ttylogin"
RFS="$ROOT/build/imagebuilder/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

[ -x "$UD" ] || fail "missing executable $UD"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat >"$W/bin/uci" <<'S'
#!/bin/sh
echo "$*" >>"$UCI_LOG"
S
chmod +x "$W/bin/uci"
UCI_LOG="$W/uci.log" PATH="$W/bin:$PATH" sh "$UD" || fail "uci-defaults script failed"
grep -qx -- "-q set system.@system\[0\].ttylogin=1" "$W/uci.log" || fail "ttylogin=1 not set: $(cat "$W/uci.log")"
grep -qx -- "-q commit system" "$W/uci.log" || fail "system not committed"
pass "uci-defaults sets ttylogin=1 and commits"

if [ -f "$RFS/usr/libexec/login.sh" ]; then
	grep -q 'ttylogin)" = 1 ] || exec /bin/login -f root' "$RFS/usr/libexec/login.sh" \
		|| fail "image login.sh no longer keys password login on ttylogin=1"
	grep -q 'askconsole:/usr/libexec/login.sh' "$RFS/etc/inittab" || fail "image console does not use login.sh"
	[ -e "$RFS/bin/login" ] || fail "image has no /bin/login"
	pass "image login.sh/inittab honour ttylogin (Image Builder rootfs)"
else
	echo "SKIP: no Image Builder rootfs (image checks)"
fi

grep -q 'passwd root' "$ROOT/files/etc/uci-defaults/92-knots-password" || fail "first-boot root password not set"
pass "root password set on first boot (label secret / knotsnode21)"

# Only the production script logs in on the console — to install the station's
# ssh key (factory password) — and it removes that key before the unit ships.
for f in "$ROOT"/factory/*.sh; do
	case "${f##*/}" in install-emmc-from-sd.sh) continue ;; esac
	grep -qE "send\(ser, *'root|write\(b?['\"]root" "$f" && fail "${f#$ROOT/} logs in on the Linux console"
done
grep -q "send(ser, 'root" "$ROOT/factory/install-emmc-from-sd.sh" && grep -q 'remove_station_key() or die' "$ROOT/factory/install-emmc-from-sd.sh" \
	|| fail "install-emmc: console login only to install the station key, removed before shipping"
pass "console login only by the production script (station key), removed before shipping"
echo "ALL PASS: test-console-login (T-CONSOLE-LOGIN)"
