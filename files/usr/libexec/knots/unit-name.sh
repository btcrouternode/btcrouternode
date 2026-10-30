#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# N20 (pre-production review, 2026-10-18): every unit's own LAN name,
# rnode-XXXX.local, XXXX = last 4 hex digits of the U-Boot ethaddr — the same
# value factory/provision-secret.sh prints on the label. Plain rnode.local
# still answers when it is the only appliance on the LAN; the unit name works
# with several. Cached in /etc/knots/unit-name so it never changes.
# Override for tests: KNOTS_UNIT_NAME, KNOTS_UNIT_NAME_FILE.

KNOTS_UNIT_NAME_FILE="${KNOTS_UNIT_NAME_FILE:-/etc/knots/unit-name}"

knots_unit_name() {
	if [ -n "${KNOTS_UNIT_NAME:-}" ]; then
		printf '%s\n' "$KNOTS_UNIT_NAME"
		return 0
	fi
	if [ -s "$KNOTS_UNIT_NAME_FILE" ]; then
		_n=$(tr -d '\r\n' <"$KNOTS_UNIT_NAME_FILE")
		case "$_n" in rnode-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s\n' "$_n"; return 0 ;; esac
	fi
	_m=$(fw_printenv -n ethaddr 2>/dev/null | tr 'A-F' 'a-f' | tr -d '\r\n')
	printf '%s' "$_m" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' || return 1
	_n="rnode-$(printf '%s' "$_m" | tr -d : | cut -c9-12)"
	mkdir -p "$(dirname "$KNOTS_UNIT_NAME_FILE")" 2>/dev/null
	printf '%s\n' "$_n" >"$KNOTS_UNIT_NAME_FILE" 2>/dev/null || true
	printf '%s\n' "$_n"
}
