#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Host unit for LED state derivation (sysfs optional)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LED="$ROOT/files/usr/libexec/knots/led-status.sh"
chmod +x "$LED"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/green" "$tmp/blue"
echo none >"$tmp/green/trigger"
echo 0 >"$tmp/green/brightness"
echo 0 >"$tmp/green/delay_on"
echo 0 >"$tmp/green/delay_off"
cp "$tmp/green/trigger" "$tmp/blue/trigger"
cp "$tmp/green/brightness" "$tmp/blue/brightness"
cp "$tmp/green/delay_on" "$tmp/blue/delay_on"
cp "$tmp/green/delay_off" "$tmp/blue/delay_off"

export KNOTS_LED_STATUS="$tmp/green"
export KNOTS_LED_ERROR="$tmp/blue"
export KNOTS_STATUS_JSON="$tmp/status.json"

# Compact JSON
cat >"$tmp/status.json" <<'EOF'
{"knots":{"running":true,"verification_progress":0.71,"blocks":100,"headers":200,"error":null},"storage":{"mounted":true}}
EOF
out=$("$LED")
[ "$out" = "syncing" ] || { echo "FAIL want syncing got $out"; exit 1; }
grep -q timer "$tmp/green/trigger" || { echo "FAIL trigger"; exit 1; }

# Pretty-printed (matches live status-api.sh)
cat >"$tmp/status.json" <<'EOF'
{
  "knots": {
    "running": true,
    "verification_progress": 0.71,
    "blocks": 100,
    "headers": 200,
    "error": null
  },
  "storage": {
    "mounted": true
  }
}
EOF
out=$("$LED")
[ "$out" = "syncing" ] || { echo "FAIL pretty syncing got $out"; exit 1; }

cat >"$tmp/status.json" <<'EOF'
{"knots":{"running":true,"verification_progress":1.0,"blocks":200,"headers":200,"error":null},"storage":{"mounted":true}}
EOF
out=$("$LED")
[ "$out" = "synced" ] || { echo "FAIL want synced got $out"; exit 1; }

cat >"$tmp/status.json" <<'EOF'
{"knots":{"running":false,"verification_progress":0,"blocks":0,"headers":0,"error":"storage_not_mounted"},"storage":{"mounted":false}}
EOF
out=$("$LED")
[ "$out" = "error" ] || { echo "FAIL want error got $out"; exit 1; }

# R-LED-MAINT (25.0.32.0 bug, user guide review 2026-11-10): during a firmware
# update or factory reset the very fast blink must stay — the node is stopped
# on purpose, so neither "booting" nor "error" may overwrite it.
export KNOTS_UPGRADE_MARK="$tmp/upgrade.active" KNOTS_RESET_MARK="$tmp/factory-reset.active"
for mark in "$KNOTS_UPGRADE_MARK" "$KNOTS_RESET_MARK"; do
	: >"$mark"
	out=$("$LED")
	[ "$out" = "maintenance" ] || { echo "FAIL want maintenance ($mark) got $out"; exit 1; }
	[ "$(cat "$tmp/green/trigger")" = timer ] && [ "$(cat "$tmp/green/delay_on")" = 100 ] \
		&& [ "$(cat "$tmp/green/delay_off")" = 100 ] || { echo "FAIL maintenance must blink green 100/100"; exit 1; }
	[ "$(cat "$tmp/blue/brightness")" = 0 ] || { echo "FAIL maintenance must not show the blue error light"; exit 1; }
	rm -f "$mark"
done
out=$("$LED")
[ "$out" = "error" ] || { echo "FAIL after the update/reset the real state must return (got $out)"; exit 1; }

echo "PASS T-LED host derive"
