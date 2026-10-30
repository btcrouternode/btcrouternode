#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# bitcoin.conf read/validate/write helpers (B22/B23) — Settings + future callers.

CONF_HOST=/srv/lxc/knots/rootfs/etc/bitcoin/bitcoin.conf
CONF_BAK=/srv/lxc/knots/rootfs/etc/bitcoin/bitcoin.conf.bak
BEGIN_EXT='# BEGIN knots-external-rpc'
END_EXT='# END knots-external-rpc'

# Allowlisted safe knobs (TECH_SPEC §7.4.2)
conf_is_allowlisted() {
	case "$1" in
		dbcache|maxconnections|maxmempool|mempoolexpiry|blocksonly|peerbloomfilters)
			return 0 ;;
		*) return 1 ;;
	esac
}

# Keys the advanced raw editor may not add, remove or change (topology, auth,
# shell hooks). B9 (review 2026-10-10): includeconf + *notify run code / pull
# in unvetted config inside the LXC, so they are protected too.
CONF_PROTECTED_KEYS="datadir prune disablewallet txindex bind rpcbind rpcallowip rpcport port \
rpcuser rpcpassword rpcauth rpcwhitelist rpcwhitelistdefault rpccookiefile wallet walletdir \
listenonion externalip proxy onion onlynet listen server includeconf conf pid debuglogfile \
alertnotify blocknotify walletnotify startupnotify shutdownnotify"
# Values never echoed back by GET conf (S4); shown as <hidden> and restored on save.
CONF_SECRET_KEYS="rpcauth rpcpassword"
CONF_HIDDEN='<hidden>'

conf_is_blocked() {
	case " $(echo $CONF_PROTECTED_KEYS) " in
		*" $1 "*) return 0 ;;
	esac
	return 1
}

# Print "key=value" for every protected setting in FILE, normalised the way
# bitcoind reads it (leading -, section prefix, spaces round =, # comments,
# noKEY negation), sorted. Two files with equal output have identical
# protected settings regardless of line order, spacing or comments.
conf_norm_protected() {
	awk -v keys="$(echo $CONF_PROTECTED_KEYS)" '
	BEGIN { n = split(keys, b, " "); for (i = 1; i <= n; i++) P[b[i]] = 1 }
	{
		line = $0
		sub(/\r$/, "", line)
		c = index(line, "#"); if (c) line = substr(line, 1, c - 1)
		sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line)
		if (line == "" || line ~ /^\[/) next
		sub(/^-+/, "", line)
		eq = index(line, "=")
		if (eq) { k = substr(line, 1, eq - 1); v = substr(line, eq + 1) }
		else { k = line; v = "1" }
		sub(/[ \t]+$/, "", k); sub(/^[ \t]+/, "", v)
		k = tolower(k)
		sub(/^(main|test|testnet4|signet|regtest)\./, "", k)
		if (!(k in P) && k ~ /^no/ && (substr(k, 3) in P)) { k = substr(k, 3); v = "!" v }
		if (k in P) print k "=" v
	}' "$1" | sort
}

# S4 — copy of FILE with secret values replaced by <hidden>.
conf_redact() {
	awk -v keys="$(echo $CONF_SECRET_KEYS)" -v hid="$CONF_HIDDEN" '
	BEGIN { n = split(keys, b, " "); for (i = 1; i <= n; i++) S[b[i]] = 1 }
	{
		if (match($0, /^[ \t]*-?[A-Za-z0-9_.]+[ \t]*=/)) {
			k = substr($0, RSTART, RLENGTH - 1)
			gsub(/[ \t-]/, "", k); k = tolower(k); sub(/^[a-z0-9]+\./, "", k)
			if (k in S) { print substr($0, 1, RSTART + RLENGTH - 1) hid; next }
		}
		print
	}' "$1"
}

# Inverse of conf_redact: each "<key>=<hidden>" line in SRC takes the next
# real value of that key from the current conf, in order.
conf_unredact() {
	src=$1
	awk -v keys="$(echo $CONF_SECRET_KEYS)" -v hid="$CONF_HIDDEN" '
	BEGIN { n = split(keys, b, " "); for (i = 1; i <= n; i++) S[b[i]] = 1 }
	function key(l,   k) {
		if (!match(l, /^[ \t]*-?[A-Za-z0-9_.]+[ \t]*=/)) return ""
		k = substr(l, RSTART, RLENGTH - 1)
		gsub(/[ \t-]/, "", k); k = tolower(k); sub(/^[a-z0-9]+\./, "", k)
		return (k in S) ? k : ""
	}
	FNR == NR { k = key($0); if (k != "") Q[k, ++cnt[k]] = substr($0, index($0, "=") + 1); next }
	{
		k = key($0)
		if (k != "" && substr($0, index($0, "=") + 1) == hid) {
			used[k]++
			if ((k, used[k]) in Q) { print substr($0, 1, index($0, "=")) Q[k, used[k]]; next }
		}
		print
	}' "$CONF_HOST" "$src"
}

conf_get_key() {
	# First non-comment assignment for KEY=
	key=$1
	[ -f "$CONF_HOST" ] || return 1
	grep -E "^[[:space:]]*${key}=" "$CONF_HOST" 2>/dev/null | head -1 | sed "s/^[[:space:]]*${key}=//"
}

conf_validate_value() {
	key=$1
	val=$2
	case "$key" in
		dbcache)
			[ "$val" -ge 64 ] 2>/dev/null && [ "$val" -le 2048 ] 2>/dev/null
			;;
		maxconnections)
			[ "$val" -ge 8 ] 2>/dev/null && [ "$val" -le 125 ] 2>/dev/null
			;;
		maxmempool)
			[ "$val" -ge 5 ] 2>/dev/null && [ "$val" -le 1000 ] 2>/dev/null
			;;
		mempoolexpiry)
			[ "$val" -ge 1 ] 2>/dev/null && [ "$val" -le 10080 ] 2>/dev/null
			;;
		blocksonly|peerbloomfilters)
			[ "$val" = "0" ] || [ "$val" = "1" ]
			;;
		*)
			return 1
			;;
	esac
}

# Print the first protected key whose settings differ between the current conf
# and RAWFILE (added, removed or changed); return 1 if none differ. Compares
# the full normalised set, so repeated keys (two bind= lines) and spacing /
# prefix / no- tricks are handled (review B9 + raw-save bind bug).
conf_raw_has_blocked() {
	rawfile=$1
	cur=$(conf_norm_protected "$CONF_HOST")
	new=$(conf_norm_protected "$rawfile")
	[ "$cur" = "$new" ] && return 1
	{ printf '%s\n' "$cur" | sed 's/^/-/'; printf '%s\n' "$new" | sed 's/^/+/'; } | \
		awk '{ s = substr($0, 1, 1); kv = substr($0, 2); if (kv == "") next
			c[kv] += (s == "+") ? 1 : -1; if (!(kv in o)) o[kv] = ++n; ord[o[kv]] = kv }
			END { for (i = 1; i <= n; i++) if (c[ord[i]] != 0) { split(ord[i], a, "="); print a[1]; exit } }'
	return 0
}

conf_extract_external_block() {
	[ -f "$CONF_HOST" ] || return 1
	awk -v b="$BEGIN_EXT" -v e="$END_EXT" '
		$0==b {p=1}
		p {print}
		$0==e {p=0}
	' "$CONF_HOST"
}

# Apply allowlisted KEY=VAL pairs; preserve external-rpc block and other lines.
# Args: pairs as "key=val" on stdin (one per line)
conf_apply_safe_pairs() {
	tmp=$(mktemp) || return 1
	ext=$(mktemp) || { rm -f "$tmp"; return 1; }
	conf_extract_external_block >"$ext" 2>/dev/null || true

	# Drop allowlisted keys and external block from base; keep everything else
	awk -v b="$BEGIN_EXT" -v e="$END_EXT" '
		$0==b {p=1; next}
		p { if ($0==e) p=0; next }
		/^[[:space:]]*dbcache=/ {next}
		/^[[:space:]]*maxconnections=/ {next}
		/^[[:space:]]*maxmempool=/ {next}
		/^[[:space:]]*mempoolexpiry=/ {next}
		/^[[:space:]]*blocksonly=/ {next}
		/^[[:space:]]*peerbloomfilters=/ {next}
		{print}
	' "$CONF_HOST" >"$tmp"

	# Append new safe values from stdin
	while IFS= read -r pair || [ -n "$pair" ]; do
		[ -n "$pair" ] || continue
		echo "$pair" >>"$tmp"
	done

	if [ -s "$ext" ]; then
		echo "" >>"$tmp"
		cat "$ext" >>"$tmp"
	fi

	cp "$CONF_HOST" "$CONF_BAK" 2>/dev/null || true
	cat "$tmp" >"$CONF_HOST"
	rm -f "$tmp" "$ext"
	return 0
}

conf_assert_product_keys() {
	# After any write — product topology must remain (B1/B9/B11)
	f=${1:-$CONF_HOST}
	grep -qE '^[[:space:]]*datadir=/mnt/bitcoin[[:space:]]*$' "$f" || return 1
	grep -qE '^[[:space:]]*disablewallet=1[[:space:]]*$' "$f" || return 1
	grep -qE '^[[:space:]]*prune=0[[:space:]]*$' "$f" || return 1
	grep -qE '^[[:space:]]*bind=21\.21\.21\.21[[:space:]]*$' "$f" || return 1
	grep -qE '^[[:space:]]*bind=\[fd21:21:21::21\][[:space:]]*$' "$f" || return 1
	grep -qE '^[[:space:]]*rpcbind=21\.21\.21\.21[[:space:]]*$' "$f" || return 1
	return 0
}

conf_write_raw_validated() {
	src=$1
	# S4 — the editor shows secrets as <hidden>; put the real values back.
	unred=$(mktemp) || return 1
	conf_unredact "$src" >"$unred" && cat "$unred" >"$src"
	rm -f "$unred"
	blocked=$(conf_raw_has_blocked "$src") && {
		echo "blocked_key:$blocked"
		return 1
	}
	conf_assert_product_keys "$src" || {
		echo "missing_product_keys"
		return 1
	}
	cp "$CONF_HOST" "$CONF_BAK" 2>/dev/null || true
	cat "$src" >"$CONF_HOST"
	return 0
}

conf_safe_json_map() {
	# Emit JSON object of allowlisted keys present (or defaults)
	dbcache=$(conf_get_key dbcache); [ -n "$dbcache" ] || dbcache=1024
	maxconnections=$(conf_get_key maxconnections); [ -n "$maxconnections" ] || maxconnections=125
	maxmempool=$(conf_get_key maxmempool); [ -n "$maxmempool" ] || maxmempool=300
	mempoolexpiry=$(conf_get_key mempoolexpiry); [ -n "$mempoolexpiry" ] || mempoolexpiry=336
	blocksonly=$(conf_get_key blocksonly); [ -n "$blocksonly" ] || blocksonly=0
	peerbloomfilters=$(conf_get_key peerbloomfilters); [ -n "$peerbloomfilters" ] || peerbloomfilters=0
	printf '{"dbcache":%s,"maxconnections":%s,"maxmempool":%s,"mempoolexpiry":%s,"blocksonly":%s,"peerbloomfilters":%s}' \
		"$dbcache" "$maxconnections" "$maxmempool" "$mempoolexpiry" "$blocksonly" "$peerbloomfilters"
}
