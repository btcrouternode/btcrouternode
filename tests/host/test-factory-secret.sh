#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-FACTORY-SECRET — review P1 / D1 / N1 (2026-10-10): per-device factory secret.
#  - knots_secret_valid: xxxx-xxxx-xxxx, alphabet without 0 1 i l o
#  - knots_factory_secret: U-Boot env knots_secret (fw_printenv) wins and is
#    mirrored to /etc/knots/factory-secret; env wiped → mirror; neither → rc 1
#  - setup_is_factory_password refuses BOTH the legacy shared password and the
#    unit's label secret
#  - wiring: seeds use knots_factory_password; default AP never re-applies once
#    done (N1); unlabelled units keep radios off; reset no longer writes the
#    shared key; Setup status exposes only a factory_labelled flag
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
cat >"$W/bin/fw_printenv" <<'EOF'
#!/bin/sh
# stub: fw_printenv -n NAME → value from $FW_ENV_FILE ("NAME=value" lines)
[ "$1" = "-n" ] || exit 1
v=$(sed -n "s/^$2=//p" "${FW_ENV_FILE:-/nonexistent}" 2>/dev/null | head -1)
[ -n "$v" ] || { echo "## Error: \"$2\" not defined" >&2; exit 1; }
printf '%s\n' "$v"
EOF
chmod +x "$W/bin/fw_printenv"
awk '/^FACTORY_PASS=/,/^FACTORY_SECRET_MIRROR=/; /^knots_secret_valid\(\)/,/^}/; /^knots_factory_secret\(\)/,/^}/; /^knots_has_factory_secret\(\)/,/^}/; /^knots_factory_password\(\)/,/^}/; /^setup_is_factory_password\(\)/,/^}/' \
	"$K/setup-lib.sh" >"$W/lib.sh"
grep -q '^knots_factory_secret()' "$W/lib.sh" || fail "helpers not found in setup-lib.sh"

run() { # ENVFILE MIRROR SNIPPET
	PATH="$W/bin:$PATH" FW_ENV_FILE=$1 FACTORY_SECRET_MIRROR=$2 sh -c ". '$W/lib.sh'; $3"
}
SEC=ab3d-ef4h-jk5m

for good in ab3d-ef4h-jk5m 2222-zzzz-x9y8; do
	run /x "$W/m" "knots_secret_valid '$good'" || fail "valid secret rejected: $good"
done
for bad in "" knotsnode21 ab3d-ef4h-jk5 AB3D-EF4H-JK5M ab3d-ef4h-jk5o ab1d-ef4h-jk5m abid-ef4h-jk5m ab3d_ef4h_jk5m "ab3d-ef4h-jk5m x"; do
	run /x "$W/m" "knots_secret_valid '$bad'" && fail "invalid secret accepted: '$bad'"
done
pass "secret format: xxxx-xxxx-xxxx, no look-alike characters"

echo "knots_secret=$SEC" >"$W/env"
[ "$(run "$W/env" "$W/mirror" knots_factory_secret)" = "$SEC" ] || fail "env secret not returned"
[ "$(cat "$W/mirror")" = "$SEC" ] || fail "env secret must be mirrored"
[ "$(stat -c %a "$W/mirror")" = 600 ] || fail "mirror must be mode 600"
[ "$(run /nonexistent "$W/mirror" knots_factory_secret)" = "$SEC" ] || fail "env wiped → mirror fallback"
echo "knots_secret=not-valid" >"$W/env-bad"
[ "$(run "$W/env-bad" "$W/mirror" knots_factory_secret)" = "$SEC" ] || fail "invalid env value → mirror fallback"
run /nonexistent "$W/none" knots_factory_secret >/dev/null && fail "unlabelled unit must return 1"
[ "$(run /nonexistent "$W/none" knots_factory_password)" = knotsnode21 ] || fail "unlabelled → legacy password"
[ "$(run "$W/env" "$W/m2" knots_factory_password)" = "$SEC" ] || fail "labelled → label secret as factory password"
pass "U-Boot env wins + mirrored (600); env wiped → mirror; unlabelled → legacy"

run "$W/env" "$W/m3" "setup_is_factory_password knotsnode21" || fail "legacy password must be refused"
run "$W/env" "$W/m3" "setup_is_factory_password $SEC" || fail "label secret must be refused as a new password"
run "$W/env" "$W/m3" "setup_is_factory_password my-new-pass" && fail "a real new password was refused"
run /nonexistent "$W/none" "setup_is_factory_password knotsnode21" || fail "legacy refused on unlabelled unit"
pass "Setup refuses legacy and label secret as new passwords"

# --- wiring ---
L="$K/setup-lib.sh"
awk '/^setup_set_root_password\(\)/,/^}/' "$L" | grep -q 'setup_is_factory_password' || fail "root password must refuse label secret"
awk '/^setup_wifi_is_factory_key\(\)/,/^}/' "$L" | grep -q 'setup_is_factory_password' || fail "Wi-Fi key must refuse label secret"
for f in "$K/factory/apply-password.sh" "$ROOT/files/etc/uci-defaults/92-knots-password"; do
	grep -q 'knots_factory_password' "$f" || fail "$(basename "$f") must use knots_factory_password"
done
WD="$K/wifi-default-enable.sh"
awk '/DONE_FILE" \]; then/{f=1} f{print} /^fi$/{if(f)exit}' "$WD" | grep -q 'exit 0' || fail "N1: DONE_FILE must exit unconditionally"
grep -q 'radio0.disabled' "$WD" && fail "N1: must not re-apply when radio0 is disabled"
grep -q 'knots_factory_secret' "$WD" || fail "default AP must use the label secret"
grep -q 'disabled=1' "$WD" || fail "unlabelled unit must keep radios off"
grep -q 'FACTORY_PASS' "$WD" && fail "default AP must not use the shared password"
grep -q 'FACTORY_PASS' "$K/factory-reset.sh" && fail "factory reset must not write the shared key"
grep -q 'factory_labelled' "$K/setup-api.sh" || fail "Setup status must expose factory_labelled"
grep -q 'wifi_on' "$K/setup-api.sh" || fail "Setup status must expose wifi_on (radios enabled in UCI)"
grep -q 'knots_factory_secret\b' "$K/setup-api.sh" && fail "Setup API must never return the secret itself"
grep -q '/etc/knots/factory-secret' "$ROOT/files/lib/upgrade/keep.d/knots" || fail "keep.d must keep the secret mirror"
pass "wiring: seeds, N1 guard, unlabelled radios off, no shared key, flag only, keep.d"

echo "ALL PASS: test-factory-secret (T-FACTORY-SECRET)"
