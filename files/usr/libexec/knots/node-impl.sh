#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# B15–B21 — Knots/Core switch + install/replace/rollback on M.2 node-bin.
set -e

. /usr/libexec/knots/node-impl-lib.sh
# json_escape for status JSON; '|| true' — node-ui.env may be absent on first boot
# shellcheck disable=SC1091
. /usr/libexec/knots/rpc.sh || true

ROOTFS=${NODE_IMPL_ROOTFS:-/srv/lxc/knots/rootfs}
BINROOT=${NODE_IMPL_BINROOT:-/mnt/bitcoin/node-bin}

# Factory pins shipped in this image (build/version.env KNOTS_TAG / CORE_TAG;
# tests/host/test-node-factory-refresh.sh checks they match).
FACTORY_KNOTS=v29.3.knots20260507
FACTORY_CORE=v29.5
# Earlier factory pins that this image replaces on the M.2, so a fix in a new
# release reaches routers already in use (29.4 → 29.5: CVE-2026-117349/117346).
# A version not listed here was installed by the owner (B19) — never touched.
OLD_FACTORY_KNOTS=""
OLD_FACTORY_CORE="v29.4"

log() { logger -t node-impl "$*"; echo "node-impl: $*" >&2; }

active_impl() { read_impl; }

bins_ok() {
	impl=$1
	[ -x "$BINROOT/$impl/bin/bitcoind" ] && [ -x "$BINROOT/$impl/bin/bitcoin-cli" ]
}

prev_ok() {
	impl=$1
	[ -x "$BINROOT/${impl}.prev/bin/bitcoind" ] && [ -x "$BINROOT/${impl}.prev/bin/bitcoin-cli" ]
}

version_of() {
	impl=$1
	root=$2
	[ -n "$root" ] || root="$BINROOT/$impl"
	if [ -f "$root/VERSION" ]; then
		cat "$root/VERSION"
		return
	fi
	if [ -x "$root/bin/bitcoind" ]; then
		ver=$(lxc-attach -n knots -- "$root/bin/bitcoind" -version 2>/dev/null \
			| sed -n 's/^.*version //p' | head -1)
		if [ -n "$ver" ]; then
			printf '%s\n' "$ver" >"$root/VERSION"
			printf '%s\n' "$ver"
			return
		fi
		# Host-exec fallback (same arch)
		ver=$("$root/bin/bitcoind" -version 2>/dev/null | sed -n 's/^.*version //p' | head -1 || true)
		if [ -n "$ver" ]; then
			printf '%s\n' "$ver" >"$root/VERSION"
			printf '%s\n' "$ver"
			return
		fi
		echo unknown
	else
		echo missing
	fi
}

json_bool() {
	[ "$1" = "true" ] && echo true || echo false
}

# Seed factory pins (B4a / B16) from LXC rootfs into M.2 node-bin when missing.
# Does not overwrite a user install (B19). UI "installed" counts M.2 only (U11).
seed_factory_impl() {
	impl=$1
	ver=$2
	src="$ROOTFS/usr/local/lib/bitcoin/$impl/bin"
	bins_ok "$impl" && return 0
	[ -x "$src/bitcoind" ] && [ -x "$src/bitcoin-cli" ] || return 0
	mkdir -p "$BINROOT/$impl/bin"
	for b in bitcoind bitcoin-cli bitcoin-tx bitcoin-util bitcoin-wallet; do
		[ -f "$src/$b" ] || continue
		cp -a "$src/$b" "$BINROOT/$impl/bin/"
	done
	printf '%s\n' "$ver" >"$BINROOT/$impl/VERSION"
	echo factory >"$BINROOT/$impl/ORIGIN"
	sync "$BINROOT/$impl/VERSION" 2>/dev/null || sync
	log "seeded factory $impl $ver → $BINROOT/$impl/bin"
}

# Replace an OLDER factory pin on the M.2 with this image's pin. Only while
# no bitcoind runs (copying over a running binary fails; knots-start calls this
# before the container starts). The replaced version is kept as <impl>.prev,
# so Rollback on the Node page still works.
refresh_factory_impl() {
	# rfi_ prefix: POSIX sh has no locals and save_prev sets impl/src/dest
	rfi_impl=$1
	rfi_ver=$2
	rfi_old=$3
	rfi_src="$ROOTFS/usr/local/lib/bitcoin/$rfi_impl/bin"
	bins_ok "$rfi_impl" || return 0
	[ "$(cat "$BINROOT/$rfi_impl/ORIGIN" 2>/dev/null)" != owner ] || return 0
	rfi_cur=$(cat "$BINROOT/$rfi_impl/VERSION" 2>/dev/null || true)
	[ "$rfi_cur" != "$rfi_ver" ] || return 0
	case " $rfi_old " in
		*" $rfi_cur "*) ;;
		*) return 0 ;;
	esac
	[ -x "$rfi_src/bitcoind" ] && [ -x "$rfi_src/bitcoin-cli" ] || return 0
	if pidof bitcoind >/dev/null 2>&1; then
		log "factory $rfi_impl $rfi_cur → $rfi_ver waits for the node to stop (next start)"
		return 0
	fi
	save_prev "$rfi_impl"
	for rfi_b in bitcoind bitcoin-cli bitcoin-tx bitcoin-util bitcoin-wallet; do
		[ -f "$rfi_src/$rfi_b" ] || continue
		cp -a "$rfi_src/$rfi_b" "$BINROOT/$rfi_impl/bin/"
	done
	printf '%s\n' "$rfi_ver" >"$BINROOT/$rfi_impl/VERSION"
	echo factory >"$BINROOT/$rfi_impl/ORIGIN"
	sync "$BINROOT/$rfi_impl/VERSION" 2>/dev/null || sync
	log "updated factory $rfi_impl $rfi_cur → $rfi_ver (previous kept for rollback)"
}

ensure_layout() {
	# Never mkdir/write under /mnt/bitcoin when unmounted (overlay poison)
	if ! m2_mounted; then
		log "M.2 not mounted — skip bin layout / state writes"
		return 1
	fi
	mkdir -p "$BINROOT/knots/bin" "$BINROOT/core/bin"
	# Adopt legacy LXC /usr/local/bin install into M.2 knots/ (frees overlay)
	if [ ! -x "$BINROOT/knots/bin/bitcoind" ] && [ -x "$ROOTFS/usr/local/bin/bitcoind" ]; then
		if [ ! -L "$ROOTFS/usr/local/bin/bitcoind" ]; then
			for b in bitcoind bitcoin-cli bitcoin-tx bitcoin-util bitcoin-wallet; do
				[ -f "$ROOTFS/usr/local/bin/$b" ] || continue
				cp -a "$ROOTFS/usr/local/bin/$b" "$BINROOT/knots/bin/"
				rm -f "$ROOTFS/usr/local/bin/$b"
			done
			echo "$FACTORY_KNOTS" >"$BINROOT/knots/VERSION"
			log "moved Knots binaries to $BINROOT/knots/bin (overlay relief)"
		fi
	fi
	# Shipped defaults: Knots B4a + Core B16 must appear installed under node-bin
	seed_factory_impl knots "$FACTORY_KNOTS"
	seed_factory_impl core "$FACTORY_CORE"
	[ -f "$BINROOT/knots/VERSION" ] || {
		[ -x "$BINROOT/knots/bin/bitcoind" ] && echo "$FACTORY_KNOTS" >"$BINROOT/knots/VERSION"
	}
	[ -f "$BINROOT/core/VERSION" ] || {
		[ -x "$BINROOT/core/bin/bitcoind" ] && echo "$FACTORY_CORE" >"$BINROOT/core/VERSION"
	}
	refresh_factory_impl knots "$FACTORY_KNOTS" "$OLD_FACTORY_KNOTS"
	refresh_factory_impl core "$FACTORY_CORE" "$OLD_FACTORY_CORE"
	reconcile_impl
}

wait_stopped() {
	i=0
	while lxc-attach -n knots -- pidof bitcoind >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 90 ] || {
			log "force-killing bitcoind"
			lxc-attach -n knots -- sh -c 'kill -9 $(pidof bitcoind) 2>/dev/null' || true
			kill -9 $(pidof bitcoind) 2>/dev/null || true
			sleep 1
			break
		}
		sleep 1
	done
}

running_cmdline() {
	lxc-attach -n knots -- sh -c '
		p=$(pidof bitcoind | awk "{print \$1; exit}")
		[ -n "$p" ] || exit 1
		tr "\0" " " <"/proc/$p/cmdline"
	' 2>/dev/null || true
}

# Post-start guard: the running bitcoind must be the M.2 node-bin binary we expect
verify_running_impl() {
	impl=$1
	cmd=$(running_cmdline)
	echo "$cmd" | grep -q "node-bin/${impl}/bin/bitcoind" || {
		echo "error: restart mismatch cmdline=$cmd" >&2
		return 1
	}
}

# U7a — detect wallet dirs without creating wallets (money-safety UX)
wallet_probe() {
	names=""
	present=false
	for w in appliance lightning; do
		if [ -d /mnt/bitcoin/wallets/"$w" ] || [ -d /mnt/bitcoin/"$w" ]; then
			present=true
			if [ -n "$names" ]; then
				names="${names},${w}"
			else
				names="$w"
			fi
		fi
	done
	printf '%s %s' "$present" "$names"
}

# ELF e_machine == 183 (0xB7) => AArch64
is_aarch64_elf() {
	f=$1
	[ -f "$f" ] || return 1
	# ELF magic. hexdump, not od: the router image has no `od` (BusyBox
	# applet not built) — every official tarball was refused on hardware
	# (2026-10-18 UAT-NB) while host tests passed with GNU od.
	mag=$(dd if="$f" bs=1 count=4 2>/dev/null | hexdump -v -e '1/1 "%02x"')
	[ "$mag" = "7f454c46" ] || return 1
	mach=$(dd if="$f" bs=1 skip=18 count=2 2>/dev/null | hexdump -v -e '1/1 "%02x"')
	# little-endian 0x00B7
	[ "$mach" = "b700" ] || [ "$mach" = "00b7" ]
}

require_wallet_ack_if_needed() {
	wallet_ack=$1
	wp=$(wallet_probe)
	w_present=$(echo "$wp" | awk '{print $1}')
	if [ "$w_present" = "true" ] && [ "$wallet_ack" != "WALLET_ACK" ]; then
		echo "error: wallet present — pass WALLET_ACK after backup warning" >&2
		return 1
	fi
	return 0
}

stop_node() {
	lxc-attach -n knots -- /usr/local/bin/knots-service stop 2>/dev/null || true
	wait_stopped
	if lxc-attach -n knots -- pidof bitcoind >/dev/null 2>&1 || pidof bitcoind >/dev/null 2>&1; then
		echo "error: bitcoind still running after stop" >&2
		return 1
	fi
}

start_node() {
	lxc-attach -n knots -- /usr/local/bin/knots-service start
	sleep 2
}

save_prev() {
	impl=$1
	dest="$BINROOT/${impl}.prev"
	src="$BINROOT/$impl"
	rm -rf "$dest"
	if [ -d "$src/bin" ] && [ -x "$src/bin/bitcoind" ]; then
		mkdir -p "$dest"
		cp -a "$src/." "$dest/"
		log "saved previous $impl -> ${impl}.prev"
	fi
}

install_bins_from_dir() {
	impl=$1
	src=$2
	ver=$3
	mkdir -p "$BINROOT/$impl/bin"
	cp -a "$src/bitcoind" "$src/bitcoin-cli" "$BINROOT/$impl/bin/"
	for b in bitcoin-tx bitcoin-util bitcoin-wallet; do
		[ -f "$src/$b" ] && cp -a "$src/$b" "$BINROOT/$impl/bin/" || true
	done
	# Regular files only — a tarball-planted symlink must not chmod its target
	find "$BINROOT/$impl/bin" -maxdepth 1 -type f -exec chmod 755 {} +
	printf '%s\n' "$ver" >"$BINROOT/$impl/VERSION"
	# The owner chose this version: a later image's factory refresh leaves it alone
	echo owner >"$BINROOT/$impl/ORIGIN"
}

detect_version_label() {
	src_bin=$1
	tgz_base=$2
	# Never execute an uploaded binary on the OpenWrt host: probe -version
	# inside the LXC container like version_of does (/mnt/bitcoin is
	# bind-mounted in). Container down → fall through to the filename label.
	ver=$(lxc-attach -n knots -- "$src_bin" -version 2>/dev/null \
		| sed -n 's/^.*version //p' | head -1 || true)
	if [ -n "$ver" ]; then
		printf '%s\n' "$ver"
		return
	fi
	# Fallback: directory / archive name hints
	case "$tgz_base" in
		*knots*)
			# X7: anchor on the "-" before the version — the greedy `.*`
			# used to eat "29." (bitcoin-29.3.knots… → "3.knots…").
			_v=$(echo "$tgz_base" | sed -n 's/^.*-v*\([0-9][0-9.]*\.knots[0-9]*\).*/\1/p' | head -1)
			[ -n "$_v" ] && echo "v$_v"
			;;
		*)
			echo "$tgz_base" | sed -n 's/.*bitcoin-\([0-9][0-9.]*\).*/v\1/p' | head -1
			;;
	esac
}

do_install_from() {
	# POSIX sh has no locals: write_impl/update_banner_impl (via ensure_layout)
	# and save_prev assign the GLOBAL 'impl'/'src'. Capture private copies so
	# the target implementation cannot be silently clobbered mid-install.
	dif_impl=$1
	tgz=$2
	sha=$3
	confirm=$4
	wallet_ack=$5

	case "$dif_impl" in
		knots|core) ;;
		*)
			echo "Usage: $0 install-from knots|core TGZ [sha256] INSTALL [WALLET_ACK]" >&2
			return 2
			;;
	esac
	[ -f "$tgz" ] || {
		echo "error: tarball not found: $tgz" >&2
		return 1
	}
	[ "$confirm" = "INSTALL" ] || {
		echo "error: refusing install without confirm token INSTALL" >&2
		return 1
	}
	m2_mounted || {
		echo "error: M.2 not mounted" >&2
		return 1
	}
	ensure_layout
	require_wallet_ack_if_needed "$wallet_ack" || return 1

	base=$(basename "$tgz")
	echo "$base" | grep -qi 'aarch64' || {
		echo "error: archive name must contain aarch64 (official linux-gnu build)" >&2
		return 1
	}
	echo "$base" | grep -qiE '\.tar\.gz$|\.tgz$' || {
		echo "error: expect .tar.gz tarball" >&2
		return 1
	}

	if [ -n "$sha" ]; then
		sha=$(echo "$sha" | tr 'A-F' 'a-f' | tr -d ' \n\r\t')
		got=$(sha256sum "$tgz" | awk '{print $1}')
		[ "$got" = "$sha" ] || {
			echo "error: sha256 mismatch (got $got)" >&2
			return 1
		}
	fi

	set_node_busy install "Node software install in progress (${dif_impl})."
	trap 'clear_node_busy; rm -rf "${tmpdir:-}"' EXIT INT TERM

	tmpdir=$(mktemp -d /mnt/bitcoin/.tmp-nodebin-XXXXXX)
	fail_install() {
		rm -rf "$tmpdir"
		echo "error: $1" >&2
		return 1
	}
	tar -xzf "$tgz" -C "$tmpdir" || fail_install "failed to extract tarball" || return 1
	dif_src=$(find "$tmpdir" -type f -name bitcoind | head -1 | xargs dirname)
	[ -n "$dif_src" ] || fail_install "no bitcoind in archive" || return 1
	[ -f "$dif_src/bitcoin-cli" ] || fail_install "bitcoin-cli missing in archive" || return 1
	is_aarch64_elf "$dif_src/bitcoind" || fail_install "bitcoind is not an AArch64 ELF binary" || return 1

	ver=$(detect_version_label "$dif_src/bitcoind" "$base")
	[ -n "$ver" ] || ver="unknown"

	act=$(active_impl)
	need_restart=false
	[ "$act" = "$dif_impl" ] && need_restart=true

	if [ "$need_restart" = "true" ]; then
		stop_node || {
			rm -rf "$tmpdir"
			return 1
		}
	fi

	save_prev "$dif_impl"
	install_bins_from_dir "$dif_impl" "$dif_src" "$ver"
	rm -rf "$tmpdir"

	if [ "$need_restart" = "true" ]; then
		start_node
		verify_running_impl "$dif_impl" || return 1
	fi

	clear_node_busy
	trap - EXIT INT TERM
	log "installed $dif_impl version=$ver restart=$need_restart"
	echo "installed $dif_impl $ver"
}

do_rollback() {
	# Same global-clobber guard as do_install_from (ensure_layout → write_impl
	# assigns the global 'impl')
	drb_impl=$1
	confirm=$2
	wallet_ack=$3

	case "$drb_impl" in
		knots|core) ;;
		*)
			echo "Usage: $0 rollback knots|core ROLLBACK [WALLET_ACK]" >&2
			return 2
			;;
	esac
	[ "$confirm" = "ROLLBACK" ] || {
		echo "error: refusing rollback without confirm token ROLLBACK" >&2
		return 1
	}
	m2_mounted || {
		echo "error: M.2 not mounted" >&2
		return 1
	}
	ensure_layout
	prev_ok "$drb_impl" || {
		echo "error: no previous $drb_impl install under ${drb_impl}.prev" >&2
		return 1
	}
	require_wallet_ack_if_needed "$wallet_ack" || return 1

	act=$(active_impl)
	need_restart=false
	[ "$act" = "$drb_impl" ] && need_restart=true
	set_node_busy rollback "Node software rollback in progress (${drb_impl})."
	trap 'clear_node_busy' EXIT INT TERM
	if [ "$need_restart" = "true" ]; then
		stop_node || return 1
	fi

	# Swap current <-> prev via staging
	stage="$BINROOT/${drb_impl}.rollback-stage"
	rm -rf "$stage"
	mkdir -p "$stage"
	if [ -d "$BINROOT/$drb_impl" ]; then
		cp -a "$BINROOT/$drb_impl/." "$stage/"
	fi
	rm -rf "$BINROOT/$drb_impl"
	mkdir -p "$BINROOT/$drb_impl"
	cp -a "$BINROOT/${drb_impl}.prev/." "$BINROOT/$drb_impl/"
	# Rolled back on purpose: the next boot must not "update" it again
	echo owner >"$BINROOT/$drb_impl/ORIGIN"
	rm -rf "$BINROOT/${drb_impl}.prev"
	mkdir -p "$BINROOT/${drb_impl}.prev"
	if [ -x "$stage/bin/bitcoind" ]; then
		cp -a "$stage/." "$BINROOT/${drb_impl}.prev/"
	fi
	rm -rf "$stage"

	ver=$(version_of "$drb_impl")
	if [ "$need_restart" = "true" ]; then
		start_node
		# Same post-start cmdline verification as install/switch
		verify_running_impl "$drb_impl" || return 1
	fi
	clear_node_busy
	trap - EXIT INT TERM
	log "rolled back $drb_impl to $ver"
	echo "rolled_back $drb_impl $ver"
}

case "${1:-status}" in
	status)
		ensure_layout 2>/dev/null || true
		act=$(active_impl)
		k_ok=false
		c_ok=false
		k_prev=false
		c_prev=false
		m2_mounted && bins_ok knots && k_ok=true
		m2_mounted && bins_ok core && c_ok=true
		m2_mounted && prev_ok knots && k_prev=true
		m2_mounted && prev_ok core && c_prev=true
		# Escape -version-derived strings before JSON embedding — a quote in a
		# version label must not break the status payload
		kv=$(json_escape "$(version_of knots)")
		cv=$(json_escape "$(version_of core)")
		kpv=missing
		cpv=missing
		[ "$k_prev" = "true" ] && kpv=$(json_escape "$(version_of knots "$BINROOT/knots.prev")")
		[ "$c_prev" = "true" ] && cpv=$(json_escape "$(version_of core "$BINROOT/core.prev")")
		running=false
		lxc-attach -n knots -- pidof bitcoind >/dev/null 2>&1 && running=true
		wp=$(wallet_probe)
		w_present=$(echo "$wp" | awk '{print $1}')
		w_names=$(echo "$wp" | awk '{print $2}')
		[ -n "$w_names" ] || w_names=""
		printf '{"ok":true,"active":"%s","default":"core","knots":{"installed":%s,"version":"%s","prev_available":%s,"prev_version":"%s"},"core":{"installed":%s,"version":"%s","prev_available":%s,"prev_version":"%s"},"running":%s,"datadir":"/mnt/bitcoin","binroot":"%s","wallet_present":%s,"wallets":"%s","note":"Shared datadir; switch/install/rollback keep chain; impl on M.2 + /etc/knots"}\n' \
			"$act" \
			"$(json_bool "$k_ok")" "$kv" "$(json_bool "$k_prev")" "$kpv" \
			"$(json_bool "$c_ok")" "$cv" "$(json_bool "$c_prev")" "$cpv" \
			"$running" "$BINROOT" "$w_present" "$w_names"
		;;
	set)
		target=${2:-}
		confirm=${3:-}
		wallet_ack=${4:-}
		case "$target" in
			knots|core) ;;
			*)
				echo "Usage: $0 set knots|core SWITCH [WALLET_ACK]" >&2
				exit 2
				;;
		esac
		m2_mounted || {
			echo "error: M.2 not mounted — cannot switch" >&2
			exit 1
		}
		ensure_layout
		cur=$(active_impl)
		# Preference refresh / IUE: already active does not require node-bin layout
		if [ "$cur" = "$target" ]; then
			write_impl "$target"
			echo "already $target"
			exit 0
		fi
		bins_ok "$target" || {
			echo "error: $target binaries not installed under $BINROOT/$target/bin — install under Node software first" >&2
			exit 1
		}
		if [ "$confirm" != "SWITCH" ]; then
			echo "Refusing switch without confirm token SWITCH" >&2
			exit 1
		fi
		require_wallet_ack_if_needed "$wallet_ack" || exit 1
		log "switching $cur -> $target"
		case "$target" in
			core) _to_label="Bitcoin Core" ;;
			*) _to_label="Bitcoin Knots" ;;
		esac
		set_node_busy switch "Node switch in progress — starting ${_to_label}."
		trap 'clear_node_busy' EXIT INT TERM
		stop_node || exit 1
		write_impl "$target"
		start_node
		cmd=$(running_cmdline)
		echo "$cmd" | grep -q "node-bin/${target}/bin/bitcoind" || {
			log "start mismatch cmd=$cmd — retry once"
			stop_node || true
			start_node
			cmd=$(running_cmdline)
		}
		echo "$cmd" | grep -q "node-bin/${target}/bin/bitcoind" || {
			# L2 (review 2026-10-11): a failed switch used to keep the new
			# impl recorded (every later start tried it again) with no node
			# running. Put the previous implementation back and start it.
			log "switch to $target failed (cmdline=$cmd) — reverting to $cur"
			stop_node || true
			write_impl "$cur"
			start_node || true
			echo "error: could not start ${_to_label}; switched back to $cur" >&2
			exit 1
		}
		clear_node_busy
		trap - EXIT INT TERM
		log "active=$target cmdline_ok"
		echo "switched_to $target"
		;;
	install-from)
		do_install_from "${2:-}" "${3:-}" "${4:-}" "${5:-}" "${6:-}"
		;;
	install-core-from)
		# Back-compat: treat as install-from core … INSTALL
		tgz=${2:-}
		sha=${3:-}
		do_install_from core "$tgz" "$sha" INSTALL WALLET_ACK
		;;
	rollback)
		do_rollback "${2:-}" "${3:-}" "${4:-}"
		;;
	ensure-default)
		if m2_mounted; then
			ensure_layout
		fi
		echo "ok $(active_impl)"
		;;
	refresh-factory)
		# Tests / support: just the factory refresh (no mount check, no reconcile)
		refresh_factory_impl knots "$FACTORY_KNOTS" "$OLD_FACTORY_KNOTS"
		refresh_factory_impl core "$FACTORY_CORE" "$OLD_FACTORY_CORE"
		echo "ok"
		;;
	reconcile)
		reconcile_impl || {
			echo "error: M.2 not mounted" >&2
			exit 1
		}
		echo "ok $(active_impl)"
		;;
	*)
		echo "Usage: $0 status|ensure-default|reconcile|set knots|core SWITCH [WALLET_ACK]|install-from knots|core TGZ [sha256] INSTALL [WALLET_ACK]|rollback knots|core ROLLBACK [WALLET_ACK]|install-core-from TGZ" >&2
		exit 2
		;;
esac
