#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-FR-BASELINE — review C7 / N3 / N14 (2026-10-10): factory reset restores
# the full owner-independent baseline.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FR="$ROOT/files/usr/libexec/knots/factory-reset.sh"
NET="$ROOT/files/usr/libexec/knots/factory/apply-network.sh"
LIB="$ROOT/files/usr/libexec/knots/setup-lib.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# N3 — /etc/hosts: every rnode.local line replaced by the baseline one
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cat >"$W/hosts" <<'EOF'
127.0.0.1 localhost
10.0.0.1 rnode.local
10.0.0.2 rnode.local # cutover alias
192.168.1.254 rnode.local
10.9.9.9 rnode.localdomain.example
EOF
hosts_edit=$(grep -E "^(sed -i -e '/\[\[:space:\]\]rnode|echo '192\.168\.1\.254 rnode\.local')" "$NET")
[ "$(printf '%s\n' "$hosts_edit" | wc -l)" = 2 ] || fail "apply-network.sh hosts edit not found"
printf '%s\n' "$hosts_edit" | sed "s|/etc/hosts|$W/hosts|g" | sh
[ "$(grep -c 'rnode\.local$' "$W/hosts")" = 1 ] || fail "exactly one rnode.local line expected"
grep -qx '192.168.1.254 rnode.local' "$W/hosts" || fail "baseline rnode.local line missing"
grep -q '^10.0.0.1 rnode.local' "$W/hosts" && fail "old LAN IP rnode.local line survived"
grep -q '10.0.0.2' "$W/hosts" && fail "cutover alias rnode.local line survived"
grep -q 'rnode.localdomain.example' "$W/hosts" || fail "unrelated host line removed"
grep -q '^127.0.0.1 localhost' "$W/hosts" || fail "localhost removed"
pass "N3 /etc/hosts rnode.local reset to the baseline line only"

# C7 — owner-specific state reset in factory-reset.sh
need() { grep -q -- "$1" "$FR" || fail "factory-reset.sh: $2"; }
need "pkill -f knots-cutover" "must stop an in-flight LAN cutover"
need "network.wan.proto='dhcp'" "must reset WAN to DHCP"
need "delete network.wan.username" "must drop PPPoE username"
need "delete network.wan.password" "must drop PPPoE password"
need "zonename='UTC'" "must reset zonename"
need "/etc/localtime" "must reset /etc/localtime"
need "rm -f /etc/knots/ui-lang" "must reset the Knots UI language"
need "luci.main.lang='auto'" "must reset the LuCI language"
need "rm -f /etc/dropbear/authorized_keys" "must remove SSH authorized_keys"
need 'REBOOT" -eq 0' "must apply the Wi-Fi baseline inline with --no-reboot"
grep -q 'wifi-default-enable.sh' "$FR" || fail "factory-reset.sh: --no-reboot must run wifi-default-enable"
# ordering: owner state must be reset before the network reload / reboot
o=$(grep -n 'pkill -f knots-cutover' "$FR" | head -1 | cut -d: -f1)
r=$(grep -n '/etc/init.d/network reload' "$FR" | head -1 | cut -d: -f1)
[ "$o" -lt "$r" ] || fail "owner state must be reset before network reload"
# wifi-default-done must be removed before the inline wifi-default-enable
d=$(grep -n 'rm -f /etc/knots/wifi-default-done' "$FR" | head -1 | cut -d: -f1)
e=$(grep -n 'wifi-default-enable.sh ||' "$FR" | head -1 | cut -d: -f1)
[ "$d" -lt "$e" ] || fail "wifi-default-done must be cleared before inline wifi-default-enable"
pass "C7 WAN/PPPoE, timezone, language, SSH keys, cutover, --no-reboot Wi-Fi"

awk '/^setup_clear_markers\(\)/,/^}/' "$LIB" | grep -q 'setup-lan-oldip' \
	|| fail "setup_clear_markers must remove setup-lan-oldip"
pass "N14 setup_clear_markers removes setup-lan-oldip"

echo "ALL PASS: test-factory-reset-baseline (T-FR-BASELINE)"
