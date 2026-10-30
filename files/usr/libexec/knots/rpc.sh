#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Shared cookie JSON-RPC helper for status/wallet APIs (host → DMZ).

ENV_FILE=/etc/knots/node-ui.env
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

RPC_HOST="${RPC_HOST:-21.21.21.21}"
RPC_PORT="${RPC_PORT:-8332}"
COOKIE_PATH="${COOKIE_PATH:-/mnt/bitcoin/.cookie}"
COOKIE_PATH_ALT="${COOKIE_PATH_ALT:-/mnt/bitcoin/bitcoin/.cookie}"
WALLET_NAME="${WALLET_NAME:-appliance}"

knots_cookie() {
	if [ -f "$COOKIE_PATH" ]; then
		cut -d: -f2 "$COOKIE_PATH"
	elif [ -f "$COOKIE_PATH_ALT" ]; then
		cut -d: -f2 "$COOKIE_PATH_ALT"
	fi
}

# knots_rpc METHOD [PARAMS_JSON] [WALLET_PATH]
# WALLET_PATH empty = toplevel; else e.g. wallet/appliance
knots_rpc() {
	method=$1
	params=${2:-[]}
	wpath=${3:-}
	cookie=$(knots_cookie)
	[ -n "$cookie" ] || return 1
	url="http://${RPC_HOST}:${RPC_PORT}/"
	[ -n "$wpath" ] && url="http://${RPC_HOST}:${RPC_PORT}/${wpath}"
	curl -sS --max-time 30 \
		--user "__cookie__:${cookie}" \
		--data-binary "{\"jsonrpc\":\"1.0\",\"id\":\"w\",\"method\":\"${method}\",\"params\":${params}}" \
		-H 'content-type: text/plain;' \
		"$url" 2>/dev/null
}

knots_wallet_rpc() {
	knots_rpc "$1" "${2:-[]}" "wallet/${WALLET_NAME}"
}

# B10 (review 2026-10-10) — also escape newline/CR/tab and drop other control
# bytes: multi-line error output or an odd SSID otherwise broke the JSON.
json_escape() {
	# tr: drop control bytes except \t \n \r; sed: escape \ " CR TAB;
	# awk: join lines with a literal \n (no backslashes in gsub replacements —
	# busybox awk and gawk disagree on those).
	printf '%s' "$1" | tr -d '\001-\010\013\014\016-\037\177' | \
		sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r/\\r/g' -e 's/\t/\\t/g' | \
		awk 'NR > 1 { printf "%s", "\\n" } { printf "%s", $0 }'
}

json_get_str() {
	# json_get_str KEY < json  — first string value for key
	key=$1
	sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p" | head -1
}

json_get_num() {
	key=$1
	sed -n "s/.*\"${key}\":\([0-9.][0-9.eE+-]*\).*/\1/p" | head -1
}
