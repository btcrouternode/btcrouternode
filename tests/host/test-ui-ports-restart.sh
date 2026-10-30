#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-UI-PORTS-RESTART — ui-ports.sh restarts uhttpd (LuCI :8443 + Knots API
# CGI :21444) only when its config or the LuCI ucode files changed. It runs at
# boot (knots-node-ui) and again from image-sync; the unconditional second
# restart dropped the Setup API mid-wizard (.79 UAT: Guided Node step → 502).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
SB="$W/sb"
mkdir -p "$SB/etc/config" "$SB/etc/init.d" "$SB/etc/knots/overlay-ui" "$SB/www/luci-static/bootstrap" \
	"$SB/www/luci-static/resources" "$W/bin"
for f in node_dashboard.uc node_dashboard.ut sysauth.ut; do
	cp "$ROOT/files/etc/knots/overlay-ui/$f" "$SB/etc/knots/overlay-ui/$f"
done
: >"$SB/etc/config/uhttpd"
printf '#!/bin/sh\necho "$1" >>"%s"\n' "$W/uhttpd.calls" >"$SB/etc/init.d/uhttpd"
chmod +x "$SB/etc/init.d/uhttpd"
# Stable fake uci: `show uhttpd` output does not change between runs.
printf '#!/bin/sh\n[ "$2" = show ] && echo "uhttpd.main.listen_https=0.0.0.0:8443"\nexit 0\n' >"$W/bin/uci"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/logger"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/pidof"   # uhttpd "running"
chmod +x "$W/bin/"*

sed -e "s|/usr/share|$SB/usr/share|g" -e "s|/usr/lib/lua|$SB/usr/lib/lua|g" \
	-e "s|/etc/knots|$SB/etc/knots|g" -e "s|/etc/config|$SB/etc/config|g" \
	-e "s|/etc/init.d|$SB/etc/init.d|g" -e "s|/www|$SB/www|g" \
	-e "s|/tmp/luci-sessions|$SB/tmp/luci-sessions|g" \
	"$ROOT/files/usr/libexec/knots/ui-ports.sh" >"$W/ui-ports.sh"
grep -nE "(^|[[:space:]=\"'])/(usr/share|usr/lib/lua|etc/knots|etc/config|etc/init\.d|www)/" "$W/ui-ports.sh" \
	&& fail "sandbox rewrite missed a path"

run() { PATH="$W/bin:$PATH" sh "$W/ui-ports.sh" 2>"$W/log.$1" || { cat "$W/log.$1" >&2; fail "ui-ports run $1"; }; }
run 1
[ "$(grep -c restart "$W/uhttpd.calls" 2>/dev/null)" = 1 ] || fail "first run (ucode files installed) must restart uhttpd"
mkdir -p "$SB/tmp/luci-sessions"; touch "$SB/tmp/luci-sessions/session-keep"
run 2
[ "$(grep -c restart "$W/uhttpd.calls")" = 1 ] || fail "unchanged second run must NOT restart uhttpd"
[ -e "$SB/tmp/luci-sessions/session-keep" ] || fail "unchanged run must keep LuCI sessions"
grep -q 'not restarted' "$W/log.2" || fail "second run should log that uhttpd was not restarted"
echo "// changed" >>"$SB/etc/knots/overlay-ui/sysauth.ut"
run 3
[ "$(grep -c restart "$W/uhttpd.calls")" = 2 ] || fail "changed LuCI template must restart uhttpd"
printf '#!/bin/sh\nexit 1\n' >"$W/bin/pidof"   # uhttpd not running
run 4
[ "$(grep -c restart "$W/uhttpd.calls")" = 3 ] || fail "uhttpd not running must be (re)started"
echo "PASS T-UI-PORTS-RESTART"
