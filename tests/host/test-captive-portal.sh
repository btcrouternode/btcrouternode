#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-CAPTIVE — first-use captive portal (captive-portal.sh, owner request
# 2026-10-24): DNS entries for the connectivity-check names point at the LAN IP
# while Setup is incomplete, follow a LAN IP change, are removed when Setup
# completes, never touch other dnsmasq address entries; setup_mark_complete and
# the LAN hotplug call it; nginx part is in test-nginx-origin.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
CP="$ROOT/files/usr/libexec/knots/captive-portal.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
echo "192.168.1.254" >"$W/ip"; : >"$W/list"; echo "/blocked.example/0.0.0.0" >>"$W/list"
cat >"$W/bin/uci" <<S
#!/bin/sh
L=$W/list
[ "\$1" = -q ] && shift
case "\$1" in
	get) case "\$2" in network.lan.ipaddr) cat $W/ip ;; dhcp.@dnsmasq\[0\].address) tr '\n' ' ' <\$L ;; esac ;;
	add_list) echo "\${2#*=}" >>\$L ;;
	del_list) grep -vxF "\${2#*=}" \$L >\$L.t || true; mv \$L.t \$L ;;
	commit) echo commit >>$W/commits ;;
esac
S
printf '#!/bin/sh\necho "$*" >>%s/log\n' "$W" >"$W/bin/logger"
cat >"$W/bin/nft" <<S
#!/bin/sh
case "\$1" in
	delete) rm -f $W/nft.rules ;;
	-f) cat >$W/nft.rules ;;
esac
exit 0
S
chmod +x "$W/bin/uci" "$W/bin/logger" "$W/bin/nft"
run() { PATH="$W/bin:$PATH" KNOTS_SETUP_COMPLETE="$W/complete" sh "$CP" "$@"; }

run sync
# check names → the PUBLIC test address (Android ignores portals on private IPs)
grep -qx "/connectivitycheck.gstatic.com/192.0.2.1" "$W/list" && grep -qx "/captive.apple.com/192.0.2.1" "$W/list" \
	|| fail "on before Setup: $(cat "$W/list")"
grep -q "192\.168\." "$W/list" && fail "a check name points at a private address: $(cat "$W/list")"
grep -q 'ip daddr 192.0.2.1 tcp dport 80 dnat to 192.168.1.254:80' "$W/nft.rules" && grep -q 'reject with tcp reset' "$W/nft.rules" \
	|| fail "nft redirect / refuse missing: $(cat "$W/nft.rules" 2>/dev/null)"
n=$(wc -l <"$W/list"); [ "$(run status)" = on ] || fail "status on"
run sync; [ "$(wc -l <"$W/list")" = "$n" ] && [ "$(grep -c commit "$W/commits")" = 1 ] || fail "second sync must not touch dnsmasq again"
echo 192.168.77.1 >"$W/ip"; run sync
grep -q 'dnat to 192.168.77.1:80' "$W/nft.rules" || fail "redirect must follow a LAN IP change: $(cat "$W/nft.rules")"
touch "$W/complete"; run sync
[ "$(cat "$W/list")" = "/blocked.example/0.0.0.0" ] || fail "after Setup only the owner's own entry may remain: $(cat "$W/list")"
[ ! -e "$W/nft.rules" ] || fail "redirect must be removed after Setup"
[ "$(run status)" = off ] || fail "status off"
pass "on until Setup completes (public test address + redirect), follows the LAN IP, idempotent, all removed after Setup, other entries untouched"

grep -q 'captive-portal.sh off' "$ROOT/files/usr/libexec/knots/setup-lib.sh" || fail "setup_mark_complete must switch it off"
grep -q 'captive-portal.sh sync' "$ROOT/files/etc/hotplug.d/iface/95-knots-avahi" || fail "LAN ifup must sync it"
for h in $(sed -n '/^HOSTS="/,/"$/p' "$CP" | tr -d '"' | sed 's/^HOSTS=//'); do
	grep -qE "^\s*$h 1;" "$ROOT/files/etc/nginx/conf.d/knots-ui.conf" || fail "nginx \$knots_captive lacks $h"
done
grep -vE '^\s*#' "$CP" | grep -q 'dnsmasq reload' && fail "captive-portal.sh must restart dnsmasq (reload = SIGHUP does not apply address= entries; .104)"
grep -vE '^\s*#' "$CP" | grep -q '/etc/init.d/dnsmasq restart' || fail "captive-portal.sh must restart dnsmasq after changing the entries"
pass "wired: Setup completion switches it off, LAN ifup syncs it, nginx knows every check host"
echo "ALL PASS: test-captive-portal (T-CAPTIVE)"
