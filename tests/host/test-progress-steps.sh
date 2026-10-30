#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-PROGRESS-STEPS — review Phase 4 L4 / L5 (2026-10-11).
#  L4  a leftover step file (e.g. "init" from a finished reset) no longer
#      blocks later progress: begin() starts clean, and a file whose wait is
#      not armed is dropped instead of re-labelling ordinary reboots.
#  L5  every factory-reset path and status fallback uses one expected
#      duration (650 s); no 150 / 300 s leftovers.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/tmp" "$W/etc" "$W/bin"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/logger"; chmod +x "$W/bin/logger"
ps() { # snippet → runs with the library sourced against the sandbox
	KNOTS_TMP="$W/tmp" KNOTS_ETC="$W/etc" PATH="$W/bin:$PATH" sh -c ". '$K/progress-steps.sh'; $1"
}
step() { ps 'progress_steps_current_step'; }

# L4 — stale "init" from a finished reset (wait no longer armed)
printf '{"kind":"reset","step":"init","label":"Opening Setup"}\n' >"$W/etc/ui-progress.json"
[ -z "$(step)" ] || fail "an unarmed leftover step must be ignored"
[ ! -f "$W/etc/ui-progress.json" ] || fail "an unarmed leftover step file must be removed"
[ -z "$(ps 'progress_steps_current_kind')" ] || fail "no kind for ordinary reboots after a stale file"
pass "stale step file (wait not armed) dropped; ordinary reboots not labelled as reset"

# L4 — begin() resets even when a higher-ranked step is present and armed
: >"$W/tmp/upgrade.active"
printf '{"kind":"upgrade","step":"init","label":"x"}\n' >"$W/tmp/ui-progress.json"
ps 'progress_steps_begin upgrade'
[ "$(step)" = stop_node ] || fail "begin must restart at stop_node (got $(step))"
ps 'progress_steps_set upgrade updating'
[ "$(step)" = updating ] || fail "forward step must apply"
ps 'progress_steps_set upgrade stop_lxc'
[ "$(step)" = updating ] || fail "steps still never go backwards within one operation"
pass "begin() starts clean; forward-only within an operation"

# Armed reset across reboot: /etc copy + pending marker keep the display
rm -f "$W/tmp/"*
: >"$W/etc/factory-reset-pending"
ps 'progress_steps_begin reset; progress_steps_set reset restarting'
rm -f "$W/tmp/ui-progress.json"            # reboot: /tmp gone
[ "$(step)" = restarting ] || fail "armed reset must survive reboot via /etc"
ps 'progress_steps_set "$(progress_steps_current_kind)" starting'
[ "$(step)" = starting ] || fail "knots-start must continue an armed reset"
pass "armed reset progress survives reboot"

# L5 — one expected duration everywhere
grep -q '^FR_EXPECTED_SECONDS=650$' "$K/factory-reset-ui.sh" || fail "FR_EXPECTED_SECONDS=650 in factory-reset-ui.sh"
grep -q 'expected=${2:-$FR_EXPECTED_SECONDS}' "$K/factory-reset-ui.sh" || fail "arm default must be FR_EXPECTED_SECONDS"
for f in "$K/settings-api.sh" "$K/setup-api.sh" "$K/factory-reset.sh" "$ROOT/files/etc/rc.button/reset"; do
	grep -nE 'fr_sec=(150|300)|factory_reset_ui_arm [a-z]+ [0-9]|"expected_seconds":(150|300)' "$f" \
		&& fail "hard-coded reset duration left in ${f#$ROOT/}"
done
out=$(KNOTS_TMP="$W/tmp" PATH="$W/bin:$PATH" sh -c ". '$K/factory-reset-ui.sh'; echo \$FR_EXPECTED_SECONDS")
[ "$out" = 650 ] || fail "FR_EXPECTED_SECONDS not visible after sourcing ($out)"
grep -q '650;' "$ROOT/files/www/knots/reset.js" || fail "reset.js default must match (650)"
pass "factory reset: one 650 s expectation for Settings, CLI, button and status fallbacks"

echo "ALL PASS: test-progress-steps (T-PROGRESS-STEPS)"
