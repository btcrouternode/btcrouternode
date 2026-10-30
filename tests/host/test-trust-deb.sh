#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# T-TRUST-DEB: the router's Ubuntu / Debian / Mint secure-connection package
# (owner 2026-10-25: App Center → Install → password, like the Mac).
#  - valid .deb (dpkg-deb), per-router name, only the CA as data
#  - postinst: system store + Firefox policy merge (other policies kept,
#    unreadable policies.json untouched); postrm undoes it
#  - router builds it with its CA; nginx serves it as a Debian package
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
F="$ROOT/files"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
command -v dpkg-deb >/dev/null || { echo "SKIP: no dpkg-deb"; exit 0; }

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$W/k" -out "$W/ca.pem" \
	-days 10 -subj "/CN=Knots Appliance CA" 2>/dev/null
sh "$F/usr/libexec/knots/mk-trust-deb.sh" "$W/ca.pem" rnode-9e3e "$W/t.deb" || fail "build"
[ "$(dpkg-deb -f "$W/t.deb" Package)" = "rnode-9e3e-secure-connection" ] || fail "package name"
dpkg-deb -f "$W/t.deb" Version | grep -qE '^1\.[0-9]{14}$' || fail "version"
[ "$(dpkg-deb -f "$W/t.deb" Architecture)" = all ] && [ "$(dpkg-deb -f "$W/t.deb" Depends)" = ca-certificates ] || fail "control"
[ "$(dpkg-deb -c "$W/t.deb" | awk '$1 !~ /^d/ {print $6}' | sort | tr '\n' ' ')" = \
	"./usr/libexec/rnode-9e3e-secure-connection/reopen-setup ./usr/local/share/ca-certificates/rnode-9e3e.crt " ] \
	|| fail "data must be the CA + the reopen helper: $(dpkg-deb -c "$W/t.deb")"
dpkg-deb -x "$W/t.deb" "$W/x"; cmp -s "$W/ca.pem" "$W/x/usr/local/share/ca-certificates/rnode-9e3e.crt" || fail "CA content"
dpkg-deb -e "$W/t.deb" "$W/c"; for s in postinst postrm; do [ -x "$W/c/$s" ] && sh -n "$W/c/$s" || fail "$s"; done
RO="$W/x/usr/libexec/rnode-9e3e-secure-connection/reopen-setup"
[ -x "$RO" ] && sh -n "$RO" && grep -q '^URL="https://rnode-9e3e.local/setup.html?after_tls=1"$' "$RO" || fail "reopen helper"
sh "$F/usr/libexec/knots/mk-trust-deb.sh" "$W/ca.pem" 'Bad Name;rm' "$W/b.deb" && [ "$(dpkg-deb -f "$W/b.deb" Package)" = rnode-secure-connection ] \
	|| fail "an odd unit name must fall back to rnode"
# reopen helper as the desktop user: Firefox running → restarted on the page;
# no Firefox → default browser (stubs record what would happen)
mkdir -p "$W/rb"; : >"$W/rcalls"
for c in pkill xdg-open firefox; do printf '#!/bin/sh\necho "%s $*" >>"%s/rcalls"\n' "$c" "$W" >"$W/rb/$c"; chmod +x "$W/rb/$c"; done
printf '#!/bin/sh\n[ -f "%s/ffup" ] && { rm -f "%s/ffup"; exit 0; }; exit 1\n' "$W" "$W" >"$W/rb/pgrep"; chmod +x "$W/rb/pgrep"
printf '#!/bin/sh\n' >"$W/rb/sleep"; chmod +x "$W/rb/sleep"
sed -e "s|/snap/bin/firefox|$W/rb/firefox|" "$RO" >"$W/ro.sh"
touch "$W/ffup"; PATH="$W/rb:$PATH" sh "$W/ro.sh"
grep -q "^pkill -u $(id -u) -x firefox|firefox-bin|firefox-esr" "$W/rcalls" && grep -q '^firefox --new-window https://rnode-9e3e.local/setup.html?after_tls=1$' "$W/rcalls" \
	|| fail "running Firefox must be restarted on the secure page: $(cat "$W/rcalls")"
: >"$W/rcalls"; PATH="$W/rb:$PATH" sh "$W/ro.sh"
[ "$(cat "$W/rcalls")" = "xdg-open https://rnode-9e3e.local/setup.html?after_tls=1" ] || fail "no Firefox → default browser: $(cat "$W/rcalls")"
pass "valid package: rnode-xxxx-secure-connection = this router's CA + a helper that reopens the secure page"

# --- postinst / postrm in a sandbox root --------------------------------------
R="$W/root"; mkdir -p "$R/etc/firefox/policies" "$R/usr/local/share/ca-certificates" "$W/bin"
cp "$W/x/usr/local/share/ca-certificates/rnode-9e3e.crt" "$R/usr/local/share/ca-certificates/"
printf '#!/bin/sh\necho "update-ca $*" >>"%s/calls"\n' "$W" >"$W/bin/update-ca-certificates"; chmod +x "$W/bin/update-ca-certificates"
for s in postinst postrm; do
	sed -e "s|/etc/firefox/policies|$R/etc/firefox/policies|g" -e "s|/usr/local/share/ca-certificates|$R/usr/local/share/ca-certificates|g" \
		-e "s|/home/\*/.pki/nssdb|$R/home/*/.pki/nssdb|g" "$W/c/$s" >"$W/$s"
done
P="$R/etc/firefox/policies/policies.json"
echo '{"policies":{"DisableTelemetry":true,"Certificates":{"Install":["/etc/other.crt"]}}}' >"$P"
for c in loginctl systemd-run runuser; do :; done
cat >"$W/bin/loginctl" <<'LC'
#!/bin/sh
case "$1" in
	list-sessions) echo "2 1000 alice seat0 tty2"; echo "7 0 root - pts/1" ;;
	show-session) case "$2:$4" in 2:Active) echo yes ;; 2:Type) echo wayland ;; 2:Name) echo alice ;; 7:Active) echo yes ;; 7:Type) echo tty ;; *) echo ;; esac ;;
esac
LC
printf '#!/bin/sh\necho "systemd-run $*" >>"%s/calls"\n' "$W" >"$W/bin/systemd-run"
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 1000; exit 0; }; exec /usr/bin/id "$@"\n' >"$W/bin/id"
chmod +x "$W/bin/loginctl" "$W/bin/systemd-run" "$W/bin/id"
PATH="$W/bin:$PATH" sh "$W/postinst" configure || fail "postinst"
[ "$(grep -c '^systemd-run' "$W/calls")" = 1 ] && grep -q '^systemd-run --user -M alice@ --collect --quiet /usr/libexec/rnode-9e3e-secure-connection/reopen-setup$' "$W/calls" \
	|| fail "postinst must reopen the page for the desktop user only: $(cat "$W/calls")"
grep -q '^update-ca $' "$W/calls" || fail "postinst must run update-ca-certificates"
python3 - "$P" "$R" <<'PY' || fail "Firefox policy after install: $(cat "$P")"
import json, sys
d = json.load(open(sys.argv[1]))["policies"]
assert d["DisableTelemetry"] is True
assert d["Certificates"]["Install"] == ["/etc/other.crt", sys.argv[2] + "/etc/firefox/policies/rnode-9e3e.crt"], d
PY
[ -f "$R/etc/firefox/policies/rnode-9e3e.crt" ] || fail "Firefox copy of the CA"
PATH="$W/bin:$PATH" sh "$W/postinst" configure; [ "$(grep -o rnode-9e3e.crt "$P" | wc -l)" = 1 ] || fail "reinstall must not duplicate"
PATH="$W/bin:$PATH" sh "$W/postrm" remove || fail "postrm"
python3 - "$P" <<'PY' || fail "Firefox policy after remove: $(cat "$P")"
import json, sys
d = json.load(open(sys.argv[1]))["policies"]
assert d == {"DisableTelemetry": True, "Certificates": {"Install": ["/etc/other.crt"]}}, d
PY
[ ! -e "$R/etc/firefox/policies/rnode-9e3e.crt" ] && grep -q '^update-ca --fresh$' "$W/calls" || fail "postrm must undo"
echo 'not json {' >"$P"; PATH="$W/bin:$PATH" sh "$W/postinst" configure
[ "$(cat "$P")" = 'not json {' ] || fail "an unreadable policies.json must be left alone"
rm -f "$P"; PATH="$W/bin:$PATH" sh "$W/postinst" configure; grep -q rnode-9e3e.crt "$P" || fail "no policies.json yet → create it"
pass "install: system store + Firefox policy (other policies kept, unreadable file untouched); remove undoes it"

# --- wiring --------------------------------------------------------------------
grep -q 'mk-trust-deb.sh" "$TLS_DIR/ca.pem" "${UNIT_NAME:-rnode}"' "$F/usr/libexec/knots/node-ui-tls.sh" || fail "router must build the package"
[ "$(grep -c 'location = /tls/rnode-secure-connection.deb' "$F/etc/nginx/conf.d/knots-ui.conf")" = 2 ] \
	&& grep -q 'default_type application/vnd.debian.binary-package' "$F/etc/nginx/conf.d/knots-ui.conf" || fail "nginx .deb location"
grep -q 'id="tlsLinuxCta" href="/tls/rnode-secure-connection.deb"' "$F/www/knots/setup.html" || fail "Setup Linux button"
grep -q 'Ctrl + Shift + V' "$F/www/knots/setup.html" || fail "Linux fallback must say how to paste"
grep -q 'Your browser reopens on the secure Setup page by itself' "$F/www/knots/setup.html" || fail "Linux reopen step"
! grep -q 'close Firefox completely' "$F/www/knots/setup.html" || fail "no manual Firefox restart step any more"
grep -q 'id="tlsWinImportant"' "$F/www/knots/setup.html" && grep -q 'More info</strong>, then <strong>Run anyway' "$F/www/knots/setup.html" \
	|| fail "Windows steps on screen"
! grep -q 'Press any button' "$F/www/knots/setup.html" || fail "Windows window closes by itself now"
pass "router builds it; nginx serves it as a Debian package; Setup shows the Linux and Windows steps"
echo "ALL PASS: test-trust-deb (T-TRUST-DEB)"
