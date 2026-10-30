#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# After sysupgrade, OpenWrt keeps /overlay — stale /www and product_version can
# shadow the new image (R14/U13). Sync appliance surfaces from /rom when the
# image build number is newer than the last sync marker.
# Does NOT touch M.2, TLS private keys, setup-complete, or UCI network/password.

set -e

MARKER=/etc/knots/.image-synced
ROM_BN=/rom/etc/knots/build_number
ROM_PV=/rom/etc/knots/product_version

image_sync_needed() {
	[ -f "$ROM_BN" ] || return 1
	rom=$(tr -d '\r\n' <"$ROM_BN")
	[ -n "$rom" ] || return 1
	mark=
	[ -f "$MARKER" ] && mark=$(tr -d '\r\n' <"$MARKER")
	ov=
	[ -f /etc/knots/product_version ] && ov=$(tr -d '\r\n' </etc/knots/product_version)
	romp=
	[ -f "$ROM_PV" ] && romp=$(tr -d '\r\n' <"$ROM_PV")
	# Sync when marker missing/different OR overlay product_version lags ROM
	if [ "$mark" != "$rom" ]; then
		return 0
	fi
	if [ -n "$romp" ] && [ "$ov" != "$romp" ]; then
		return 0
	fi
	return 1
}

image_sync_from_rom() {
	image_sync_needed || return 0
	rom=$(tr -d '\r\n' <"$ROM_BN")
	logger -t knots-image-sync "applying /rom appliance files for build $rom"

	mkdir -p /etc/knots /www/knots /usr/libexec/knots /etc/nginx/conf.d

	# Version stamps (so Settings shows the new build after web upgrade)
	if [ -f "$ROM_PV" ]; then
		cp -a "$ROM_PV" /etc/knots/product_version
		cp -a "$ROM_PV" /etc/product_version 2>/dev/null || true
	fi
	if [ -f /rom/etc/knots/build_number ]; then
		cp -a /rom/etc/knots/build_number /etc/knots/build_number
	fi
	if [ -f /rom/etc/knots/versions.env ]; then
		cp -a /rom/etc/knots/versions.env /etc/knots/versions.env
		cp -a /rom/etc/knots/versions.env /etc/versions.env 2>/dev/null || true
	fi

	# Node UI + Setup + TLS install scripts
	if [ -d /rom/www/knots ]; then
		cp -a /rom/www/knots/. /www/knots/
	fi

	# LuCI skin (Node Status palette) + return bar — refresh cascade via ui-ports
	mkdir -p /www/luci-static/bootstrap /www/luci-static/resources
	if [ -f /rom/www/luci-static/bootstrap/knots-return.css ]; then
		cp -a /rom/www/luci-static/bootstrap/knots-return.css \
			/www/luci-static/bootstrap/knots-return.css
	fi
	if [ -f /rom/www/luci-static/resources/knots-return.js ]; then
		cp -a /rom/www/luci-static/resources/knots-return.js \
			/www/luci-static/resources/knots-return.js
	fi
	if [ -f /rom/www/luci-entry.html ]; then
		cp -a /rom/www/luci-entry.html /www/luci-entry.html
	fi
	if [ -f /rom/etc/knots/overlay-ui/sysauth.ut ]; then
		mkdir -p /etc/knots/overlay-ui
		cp -a /rom/etc/knots/overlay-ui/sysauth.ut /etc/knots/overlay-ui/sysauth.ut
	fi

	# CGI / helpers (preserve executable bits from rom)
	if [ -d /rom/usr/libexec/knots ]; then
		cp -a /rom/usr/libexec/knots/. /usr/libexec/knots/
	fi
	chmod 755 /usr/libexec/knots/*.sh 2>/dev/null || true
	chmod 755 /usr/libexec/knots/wallet-cgi/api/* 2>/dev/null || true

	# S7 — remove retired on-device wipe surfaces shadowed by overlay (F86/F87)
	rm -f /usr/libexec/knots/storage-wipe.sh \
		/usr/libexec/knots/storage-api.sh \
		/usr/libexec/knots/wallet-cgi/api/storage \
		/www/knots/storage.html \
		/www/knots/storage.js 2>/dev/null || true
	if [ -f /rom/usr/sbin/knots-storage ]; then
		cp -a /rom/usr/sbin/knots-storage /usr/sbin/knots-storage
		chmod 755 /usr/sbin/knots-storage
	fi
	if [ -f /rom/usr/libexec/knots/factory-reset.sh ]; then
		cp -a /rom/usr/libexec/knots/factory-reset.sh /usr/libexec/knots/factory-reset.sh
		chmod 755 /usr/libexec/knots/factory-reset.sh
	fi
	if [ -f /rom/usr/sbin/factory-reset ]; then
		cp -a /rom/usr/sbin/factory-reset /usr/sbin/factory-reset
		chmod 755 /usr/sbin/factory-reset
	fi

	# Re-inline LuCI theme into cascade.css (overlay may retain stale cascade)
	if [ -x /usr/libexec/knots/ui-ports.sh ]; then
		/usr/libexec/knots/ui-ports.sh || true
	fi

	# nginx Knots vhost (must include /api/setup etc.)
	if [ -f /rom/etc/nginx/conf.d/knots-ui.conf ]; then
		cp -a /rom/etc/nginx/conf.d/knots-ui.conf /etc/nginx/conf.d/knots-ui.conf
	fi

	# U18 reboot wrappers
	for w in reboot poweroff halt; do
		if [ -f "/rom/sbin/$w" ]; then
			cp -a "/rom/sbin/$w" "/sbin/$w"
			chmod 755 "/sbin/$w"
		fi
	done

	printf '%s\n' "$rom" >"$MARKER"
	logger -t knots-image-sync "done build=$rom product=$(cat /etc/knots/product_version 2>/dev/null)"
	# Reload web stack if already up
	/usr/libexec/knots/nginx-apply.sh 2>/dev/null || true
	[ -x /etc/init.d/uhttpd ] && /etc/init.d/uhttpd reload 2>/dev/null || true
	return 0
}

# Allow: . /usr/libexec/knots/image-sync.sh && image_sync_from_rom
# Or: image-sync.sh run
if [ "${0##*/}" = "image-sync.sh" ]; then
	case "${1:-run}" in
		run|sync) image_sync_from_rom ;;
		needed) image_sync_needed ;;
		*) echo "Usage: $0 run|needed" >&2; exit 2 ;;
	esac
fi
