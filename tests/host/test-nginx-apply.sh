#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NGX-APPLY — .92 UAT-UR-2 (2026-10-11): nginx config changes never drop
# connections and never overlap.
#  - running nginx → reload (not restart); not running → start
#  - concurrent callers are serialized (no overlapping uci.conf regeneration)
#  - no Knots script restarts nginx or calls its reload directly
#  - the first-boot 25 s knots-node-ui retry only runs when nginx is down
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
F="$ROOT/files"
H="$F/usr/libexec/knots/nginx-apply.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v flock >/dev/null 2>&1 || { echo "SKIP T-NGX-APPLY: no flock"; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
# fake init: logs begin/end with a small overlap window
cat >"$W/init" <<EOF2
#!/bin/sh
echo "begin \$1" >>"$W/log"; sleep 0.3; echo "end \$1" >>"$W/log"
EOF2
printf '#!/bin/sh\n[ -f "%s/running" ]\n' "$W" >"$W/bin/pidof"
printf '#!/bin/sh\nexit 0\n' >"$W/bin/logger"
chmod +x "$W/init" "$W/bin/"*
run() { NGINX_INIT="$W/init" KNOTS_TMP="$W" PATH="$W/bin:$PATH" sh "$H"; }

: >"$W/log"; : >"$W/running"; run
[ "$(cat "$W/log")" = "begin reload
end reload" ] || fail "running nginx must be reloaded, not restarted: $(cat "$W/log")"
rm -f "$W/running"; : >"$W/log"; run
grep -q '^begin start$' "$W/log" || fail "stopped nginx must be started"
pass "running → reload (sockets kept); stopped → start"

: >"$W/running"; : >"$W/log"
run & run & run & wait
awk '/^begin/{ if (open) bad=1; open=1 } /^end/{ open=0 } END { exit bad }' "$W/log" \
	|| fail "concurrent applies overlapped: $(tr '\n' ' ' <"$W/log")"
[ "$(grep -c '^begin reload' "$W/log")" = 3 ] || fail "every caller must apply once"
pass "concurrent callers serialized (no overlapping reloads)"

bad=$(grep -rn 'init.d/nginx \(restart\|reload\)' "$F" | grep -v 'nginx-apply.sh' || true)
[ -z "$bad" ] || fail "direct nginx restart/reload left:
$bad"
for f in etc/init.d/knots-node-ui etc/hotplug.d/iface/90-knots-lan-addrs usr/libexec/knots/node-ui-tls.sh usr/libexec/knots/image-sync.sh; do
	grep -q 'nginx-apply.sh' "$F/$f" || fail "$f must use nginx-apply.sh"
done
grep -q 'sleep 25; pidof nginx >/dev/null 2>&1 || /etc/init.d/knots-node-ui start' "$F/etc/uci-defaults/99-bitcoin-node" \
	|| fail "first-boot retry must only start the web stack when nginx is down"
pass "all Knots nginx changes go through nginx-apply; first-boot retry conditional"
echo "ALL PASS: test-nginx-apply (T-NGX-APPLY)"
