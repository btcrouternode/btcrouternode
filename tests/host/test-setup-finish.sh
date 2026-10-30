#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-SETUP-FINISH — review Phase 5 (2026-10-11): Setup wizard / cutover.
#  C5  LAN validation refuses addresses that strand the appliance.
#  C2  Finish is validate-all → uci set → commit together; a bad staged value
#      changes nothing; node switch is deferred to the cutover worker.
#  C1  Quick Start validates everything (incl. Wi-Fi key) before applying.
#  C3  cutover: alias only after the new IP is up, old mask for the alias,
#      temporary rnode.local in /tmp/hosts, mask-only / DHCP-only changes
#      applied, node switch last.
#  C4  Wi-Fi client detection / deauth via hostapd ubus (no brctl/hostapd_cli).
#  C6  UTC (country 00) never reaches the radios.
#  C9  a reset that never ran cannot trap the UI on the reset page.
#  C10 implementation readers go through read_impl.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
LIB="$K/setup-lib.sh"; API="$K/setup-api.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
for t in logger; do printf '#!/bin/sh\nexit 0\n' >"$W/bin/$t"; done
# fake uci: key=value store with set / get / show / commit / revert logging
cat >"$W/bin/uci" <<EOF
#!/bin/sh
DB="$W/uci.db"; LOG="$W/uci.log"
[ "\$1" = -q ] && shift
case "\$1" in
get) v=\$(grep "^\$2=" "\$DB" 2>/dev/null | tail -1 | cut -d= -f2-); [ -n "\$v" ] || exit 1; echo "\$v" ;;
set) echo "set \$2" >>"\$LOG"; echo "\$2" >>"\$DB" ;;
show) grep "^\$2" "\$DB" 2>/dev/null | sed 's/^\\([^=]*\\)=\\(wifi-device\\|wifi-iface\\)\$/\\1=\\2/' ;;
commit) echo "commit \$2" >>"\$LOG" ;;
revert) echo "revert \$2" >>"\$LOG" ;;
esac
exit 0
EOF
chmod +x "$W/bin/"*
lib() { # snippet with setup-lib sourced against the sandbox
	PATH="$W/bin:$PATH" SETUP_HOSTS_FILE="$W/hosts" SETUP_ETC="$W/etc" sh -c ". '$LIB'; SETUP_PENDING_DIR='$W/pending'; $1"
}

# --- C5 LAN validation table
ok_lan() { lib "setup_lan_validate $1" || fail "LAN should be accepted: $1"; }
bad_lan() { lib "setup_lan_validate $1" && fail "LAN must be refused: $1"; true; }
ok_lan "192.168.1.254 255.255.255.0 100 101"
ok_lan "10.0.0.1 255.255.255.0 100 150"
ok_lan "172.16.5.1 255.255.0.0 100 1000"
ok_lan "192.168.50.1 255.255.255.192 10 40"
for bad in "0.0.0.0 255.255.255.0 100 101" "127.0.0.1 255.255.255.0 100 101" \
	"224.0.0.1 255.255.255.0 100 101" "8.8.8.8 255.255.255.0 100 101" \
	"21.21.21.5 255.255.255.0 100 101" "192.168.1.0 255.255.255.0 100 101" \
	"192.168.1.255 255.255.255.0 100 101" "192.168.01.1 255.255.255.0 100 101" \
	"192.168.1.1 255.255.255.0 100 200" "192.168.1.150 255.255.255.0 100 101" \
	"192.168.50.1 255.255.255.192 10 60" "192.168.1.1 255.0.255.0 100 101" \
	"192.168.1 255.255.255.0 100 101" "192.168.1.1 255.255.255.0 0 101"; do
	bad_lan "$bad"
done
pass "C5 LAN validation: private only, not net/broadcast/DMZ/loopback/multicast, pool inside subnet and not the router"

# --- C2 transactional Finish
seed() {
	: >"$W/uci.log"; rm -rf "$W/pending"; echo '1.1.1.1 old' >"$W/hosts"; echo '192.168.1.254 rnode.local' >>"$W/hosts"
	printf '%s\n' network.lan.ipaddr=192.168.1.254 network.lan.netmask=255.255.255.0 \
		dhcp.lan.start=100 dhcp.lan.limit=101 wireless.radio0=wifi-device wireless.default_radio0=wifi-iface \
		wireless.default_radio0.key=oldkey12345 >"$W/uci.db"
}
pend() { lib "setup_pending_set $1 '$2'"; }
seed
pend lan_ipaddr 10.20.30.1; pend lan_netmask 255.255.255.0; pend lan_dhcp_start 100; pend lan_dhcp_limit 50
pend wifi_ssid myhome; pend wifi_key 'goodpassw0rd'; pend wifi_country AU
out=$(lib 'setup_apply_staged_finish') || { cat "$W/uci.log"; fail "valid Finish must apply"; }
[ "$out" = "192.168.1.254 10.20.30.1 255.255.255.0 1 1 1 -" ] || fail "Finish summary: '$out'"
for c in network dhcp wireless; do grep -q "^commit $c$" "$W/uci.log" || fail "Finish must commit $c"; done
grep -q 'set network.lan.ipaddr=10.20.30.1' "$W/uci.log" || fail "LAN IP not set"
grep -q 'set wireless.default_radio0.key=goodpassw0rd' "$W/uci.log" || fail "Wi-Fi key not set"
grep -q '^10.20.30.1 rnode.local$' "$W/hosts" && ! grep -q '^192.168.1.254 rnode.local' "$W/hosts" \
	&& grep -q '1.1.1.1 old' "$W/hosts" || fail "rnode.local line must move to the new IP only ($(cat "$W/hosts"))"
grep -q '^AU$' "$W/etc/wifi-country" || fail "Finish must record the applied Wi-Fi country"
pass "C2 valid Finish: set LAN + DHCP + Wi-Fi, commit together, summary for the cutover"

seed
pend lan_ipaddr 192.168.1.0; pend wifi_key 'goodpassw0rd'
lib 'setup_apply_staged_finish' >/dev/null && fail "invalid staged LAN must fail Finish"
grep -q '^set\|^commit' "$W/uci.log" && fail "invalid Finish must change nothing ($(cat "$W/uci.log"))"
seed
pend wifi_key knotsnode21
lib 'setup_finish_validate || { echo "$SETUP_ERR_CODE"; exit 1; }' >"$W/o" && fail "factory Wi-Fi key must fail validation"
grep -q factory_forbidden "$W/o" || fail "factory key → factory_forbidden ($(cat "$W/o"))"
seed
pend node_impl knots
lib 'setup_finish_validate || { echo "$SETUP_ERR_CODE"; exit 1; }' >"$W/o" && fail "uninstalled node must fail validation"
grep -q node_missing "$W/o" || fail "missing node → node_missing"
pass "C2 invalid staged value (LAN / factory key / missing node) refused before any change"

# mask-only change on the same IP is reported for the cutover (C3/K2)
seed
pend lan_ipaddr 192.168.1.254; pend lan_netmask 255.255.0.0; pend lan_dhcp_start 100; pend lan_dhcp_limit 101
out=$(lib 'setup_apply_staged_finish')
[ "$out" = "192.168.1.254 192.168.1.254 255.255.255.0 0 1 0 -" ] || fail "mask-only change summary: '$out'"
pass "C3 same-IP mask change flagged (lan_cfg=1) with the OLD mask for the hold alias"

# --- C1 Quick Start order: everything validated before the first apply
qs=$(awk '/^\tquickstart\)/,/^\t\t;;/' "$API")
first_apply=$(printf '%s\n' "$qs" | grep -n 'setup_set_root_password\|^\t\tsetup_locale_apply\|setup_wan_apply_dhcp' | head -1 | cut -d: -f1)
for v in 'setup_is_factory_password "$p1"' 'SETUP_LOCALE_CHECK_ONLY=1 setup_locale_apply' 'setup_wifi_validate rnode' 'setup_wifi_is_factory_key "$wkey"'; do
	n=$(printf '%s\n' "$qs" | grep -nF "$v" | head -1 | cut -d: -f1)
	[ -n "$n" ] && [ "$n" -lt "$first_apply" ] || fail "C1: '$v' must run before anything is applied"
done
printf '%s\n' "$qs" | grep -q 'setup_node_set' && fail "C1: Quick Start must not switch the node in the CGI"
printf '%s\n' "$qs" | grep -q 'json_escape_local "\$out"' && fail "C1: no double-escaped error JSON"
grep -q 'setup_pending_clear' <<EOF || fail "Finish must clear the staging dir (plaintext Wi-Fi key)"
$(awk '/^setup_finish_and_respond\(\)/,/^}/' "$API")
EOF
pass "C1 Quick Start validates all before applying; shared Finish clears pending; node not switched in CGI"

# --- C3 cutover structure
co=$(awk '/^setup_cutover_now\(\)/,/^}/' "$LIB")
printf '%s\n' "$co" | awk '/setup_wait_lan_ip/{w=NR} /ip addr add/{a=NR} END{exit !(w && a && w < a)}' \
	|| fail "C3: alias must be added after the new IP is up"
printf '%s\n' "$co" | grep -q 'SETUP_CUTOVER_HOSTS' || fail "C3: temporary rnode.local must use /tmp/hosts"
printf '%s\n' "$co" | grep -q '/etc/hosts' && fail "C3: cutover must not write /etc/hosts (survives reboot)"
printf '%s\n' "$co" | grep -q 'elif \[ "\$lan_cfg" = 1 \]' || fail "C3: mask-only change must reload the network"
printf '%s\n' "$co" | grep -q 'elif \[ "\$dhcp_chg" = 1 \]' || fail "C3: DHCP-only change must reload dnsmasq"
printf '%s\n' "$co" | awk '/setup_cutover_node/{n=NR} /wifi reload/{w=NR} END{exit !(n > w)}' || fail "C3: node switch must come last"
for dead in setup_schedule_lan_apply setup_apply_lan_now setup_schedule_wifi_reload setup_lan_apply setup_schedule_reboot; do
	grep -q "^$dead()" "$LIB" && fail "dead helper $dead must be removed"
done
[ "$(grep -c '^setup_[a-z_]*()' "$LIB")" = "$(grep '^setup_[a-z_]*()' "$LIB" | sort -u | wc -l)" ] || fail "duplicate function definitions"
grep -q '^SETUP_CUTOVER_HOSTS=/tmp/hosts/' "$LIB" || fail "cutover hosts file must live under /tmp/hosts"
pass "C3 cutover: alias after ifup, /tmp/hosts, mask/DHCP-only applied, node last; dead helpers gone"

# --- C4 hostapd ubus
cw=$(awk '/^setup_client_on_wifi\(\)/,/^}/' "$LIB"; awk '/^setup_wifi_deauth_stations\(\)/,/^}/' "$LIB")
printf '%s\n' "$cw" | grep -qE 'brctl|hostapd_cli|brport' && fail "C4: no brctl / hostapd_cli / brport lookups"
printf '%s\n' "$cw" | grep -q 'get_clients' && printf '%s\n' "$cw" | grep -q 'del_client' \
	|| fail "C4: use hostapd ubus get_clients / del_client"
pass "C4 Wi-Fi client detection + deauth via hostapd ubus"

# --- C6 UTC never reaches radios
seed
lib "SETUP_LOCALE_CHECK_ONLY=1 REGIONS_JSON='$ROOT/files/www/knots/i18n/regions.json'; setup_locale_apply en '' UTC" \
	|| fail "UTC must be a valid locale"
lib "setup_wifi_set_uci rnode goodpassw0rd 00 && echo \$SETUP_WIFI_CC" >"$W/o"
grep -q '^AU$' "$W/o" || fail "C6: country 00 must map to the factory country ($(cat "$W/o"))"
grep -q 'country=00' "$W/uci.log" && fail "C6: country 00 written to a radio"
awk '/^setup_locale_apply\(\)/,/^}/' "$LIB" | grep -q 'radio_cc=\$FACTORY_WIFI_COUNTRY' || fail "C6: locale must map 00 for radios"
pass "C6 country 00 (UTC) mapped to the factory country for radios"

# --- C9 / C10
grep -q '^factory_reset_ui_reap_stale()' "$K/factory-reset-ui.sh" || fail "C9: stale reset reaper missing"
grep -q 'factory_reset_ui_reap_stale' "$API" && grep -q 'factory_reset_ui_reap_stale' "$K/settings-api.sh" \
	|| fail "C9: both status endpoints must reap a stale reset marker"
awk '/^setup_complete_check\(\)/,/^}/' "$API" | grep -q factory_reset_clear && fail "C9: factory_reset_clear must stay open after Setup"
for f in bitcoind-ctl.sh status-api.sh setup-lib.sh; do
	grep -n 'cat /mnt/bitcoin/.node-impl' "$K/$f" && fail "C10: $f must use read_impl"
done
grep -rq 'Leave Bitcoin Knots selected' "$K" && fail "C10: default text must say Core"
pass "C9 stale reset marker reaped; C10 one impl reader, Core default text"

echo "ALL PASS: test-setup-finish (T-SETUP-FINISH)"
