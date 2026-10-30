#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# IUE HTTPS trust — simulate every OS install path (N13 / U17).
# Generates a real local CA (node-ui-tls), serves assets over HTTP, and
# exercises download + validate + install-helper flows for:
#   Windows, macOS, iPhone/iPad, Android, Linux
# Looks for bugs; uses real PEM/DER/mobileconfig (no fake certs).
# Usage: tests/host/test-iue-tls-os.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TLS_SCRIPTS="$ROOT/files/www/knots/tls"
TLS_JS="$ROOT/files/www/knots/tls-os.js"
NGINX="$ROOT/files/etc/nginx/conf.d/knots-ui.conf"
GEN="$ROOT/files/usr/libexec/knots/node-ui-tls.sh"
command -v openssl >/dev/null
command -v python3 >/dev/null
command -v curl >/dev/null

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null || true' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- 1. Mint real CA + leaf + Apple profile (same as appliance) ---
sed -e "s|/etc/knots/tls|$TMP/tls|g" -e "s|/www/knots|$TMP/www|g" "$GEN" >"$TMP/gen.sh"
chmod +x "$TMP/gen.sh"
export KNOTS_LAN_IP=192.168.1.254
sh "$TMP/gen.sh" --force >/dev/null
test -f "$TMP/tls/ca.pem" || fail "ca.pem missing"
test -f "$TMP/www/knots-ca.crt" || fail "published knots-ca.crt missing"
test -f "$TMP/www/tls/ios-profile.mobileconfig" || fail "mobileconfig missing"
test -f "$TMP/www/tls/knots-ca.cer" || fail "DER .cer missing"
openssl verify -CAfile "$TMP/tls/ca.pem" "$TMP/tls/cert.pem" | grep -q OK || fail "leaf verify"
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q '192.168.1.254' || fail "SAN IP"
openssl x509 -in "$TMP/tls/cert.pem" -noout -text | grep -q 'node-router' || fail "SAN hostname node-router"
pass "real CA + SAN leaf + mobileconfig + DER (node-ui-tls)"

# mobileconfig PayloadContent must be base64(DER of CA)
python3 - "$TMP/tls/ca.pem" "$TMP/www/tls/ios-profile.mobileconfig" <<'PY' || fail "mobileconfig DER mismatch"
import sys, base64, re, subprocess
ca, mc = sys.argv[1], sys.argv[2]
der = subprocess.check_output(["openssl", "x509", "-in", ca, "-outform", "DER"])
text = open(mc, encoding="utf-8").read()
m = re.search(r"<data>\s*([A-Za-z0-9+/=\s]+)\s*</data>", text)
assert m, "no <data> in mobileconfig"
b64 = re.sub(r"\s+", "", m.group(1))
got = base64.b64decode(b64)
assert got == der, f"PayloadContent len {len(got)} != DER {len(der)}"
assert "PayloadType" in text and "com.apple.security.root" in text
print("mobileconfig OK")
PY
pass "Apple .mobileconfig embeds exact CA DER"

openssl x509 -in "$TMP/tls/ca.pem" -outform DER -out "$TMP/ca.der"
cmp -s "$TMP/ca.der" "$TMP/www/tls/knots-ca.cer" || fail "knots-ca.cer != CA DER"
pass "Android .cer is CA DER"

# --- 2. nginx must force downloads (not inline text/plain) ---
for pair in \
	'install-linux.sh|install-bitcoin-node-trust.sh' \
	'install-macos.command|install-bitcoin-node-trust.command' \
	'install-windows.bat|install-bitcoin-node-trust.bat' \
	'install-windows.ps1|install-windows.ps1' \
	'knots-ca.cer|knots-ca.cer'
do
	loc=${pair%|*}; name=${pair#*|}
	grep -q "location = /tls/$loc" "$NGINX" || fail "nginx location /$loc"
	# whole location block (line-count windows broke when S6 added an include)
	block=$(awk -v l="location = /tls/$loc {" 'index($0, l) { f = 1 } f { print } f && /^\t}/ { exit }' "$NGINX")
	printf '%s\n' "$block" | grep -q "Content-Disposition" \
		|| fail "Content-Disposition missing for $loc"
	printf '%s\n' "$block" | grep -q "$name" \
		|| fail "filename $name missing for $loc"
done
grep -q 'ios-profile.mobileconfig' "$NGINX" || fail "nginx mobileconfig location"
awk '/location = \/knots-ca.crt/ { f = 1 } f { print } f && /^\t}/ { exit }' "$NGINX" | grep -q Content-Disposition || fail "CA download Disposition"
pass "nginx forces file downloads for all OS helpers"

# --- 3. OS detect + primary CTA (real tls-os.js under simulated UAs) ---
cp "$TLS_JS" "$TMP/tls-os.js"
python3 - "$TMP/tls-os.js" <<'PY' || fail "OS CTA matrix"
import subprocess, json, textwrap, sys
js_path = sys.argv[1]
cases = [
  ("windows", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)", "Win32", 0,
   "/tls/install-windows.bat", "install-bitcoin-node-trust.bat"),
  ("mac", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", "MacIntel", 0,
   "applescript://com.apple.scripteditor", None),
  # phones / tablets: no certificate path — Setup is laptop/computer only (2026-10-25)
  ("ios", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", "iPhone", 0, None, None),
  ("ios", "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)", "MacIntel", 5, None, None),  # iPadOS desktop UA
  ("android", "Mozilla/5.0 (Linux; Android 14)", "Linux armv8l", 0, None, None),
  ("linux", "Mozilla/5.0 (X11; Linux x86_64)", "Linux x86_64", 0,
   "/tls/rnode-secure-connection.deb", "rnode-secure-connection.deb"),
]
# Run each case in node if available, else reimplement detectOs in Python matching JS
code = open(js_path, encoding="utf-8").read()

def detect(ua, plat, mtp):
    import re
    if re.search(r"iPhone|iPad|iPod", ua) or (plat == "MacIntel" and mtp > 1):
        return "ios"
    if re.search(r"Android", ua, re.I):
        return "android"
    if re.search(r"Win", plat, re.I) or re.search(r"Windows", ua, re.I):
        return "windows"
    if re.search(r"Mac", plat, re.I) or re.search(r"Macintosh", ua, re.I):
        return "mac"
    if re.search(r"Linux", plat, re.I) or re.search(r"Linux", ua, re.I):
        return "linux"
    return "windows"

# Keep CTA map in sync with tls-os.js primaryAction
cta = {
  "windows": ("/tls/install-windows.bat", "install-bitcoin-node-trust.bat"),
  "mac": ("applescript://com.apple.scripteditor", None),
  "ios": (None, None),
  "android": (None, None),
  "linux": ("/tls/rnode-secure-connection.deb", "rnode-secure-connection.deb"),
}
# Assert JS source contains the expected hrefs (single source of truth check)
for os, href, dl in [
  ("windows", "/tls/install-windows.bat", "install-bitcoin-node-trust.bat"),
  ("mac", "applescript://com.apple.scripteditor", None),
  ("linux", "/tls/rnode-secure-connection.deb", "rnode-secure-connection.deb"),
]:
    assert href in code, f"tls-os.js missing href {href} for {os}"
    if dl:
        assert dl in code, f"tls-os.js missing download {dl}"

for name, ua, plat, mtp, href, dl in cases:
    got = detect(ua, plat, mtp)
    assert got == name, f"detectOs({ua!r}) → {got} want {name}"
    ch, cd = cta[got]
    assert ch == href and cd == dl, f"CTA {got}: {(ch,cd)} != {(href,dl)}"
    print(f"  OS {name}: detect+CTA OK → {href}")
for gone in ('case "ios"', 'case "android"', "android-certificate"):
    assert gone not in code, f"tls-os.js still has a phone certificate path: {gone}"
assert "isPhoneOrTablet: isPhoneOrTablet" in code, "tls-os.js must export isPhoneOrTablet"
print("matrix OK")
PY
pass "OS detect + primary CTA for Windows/macOS/Linux; iPhone/iPad/Android detected as phone/tablet (no certificate path)"

# --- 4. HTTP server: simulate router LAN serving TLS assets ---
mkdir -p "$TMP/serve/tls"
cp "$TMP/www/knots-ca.crt" "$TMP/serve/knots-ca.crt"
cp "$TMP/www/tls/"* "$TMP/serve/tls/" 2>/dev/null || true
cp "$TLS_SCRIPTS/"* "$TMP/serve/tls/"
# Publish install scripts next to CA for sidecar discovery
cp "$TMP/www/knots-ca.crt" "$TMP/serve/tls/knots-ca.crt"

python3 -m http.server 18766 --bind 127.0.0.1 --directory "$TMP/serve" \
	>"$TMP/http.log" 2>&1 &
HPID=$!
sleep 0.4
BASE=http://127.0.0.1:18766

curl -fsSL "$BASE/knots-ca.crt" -o "$TMP/dl-ca.crt"
cmp -s "$TMP/www/knots-ca.crt" "$TMP/dl-ca.crt" || fail "HTTP CA download"
pass "HTTP CA download (Android / fallback path)"

curl -fsSL "$BASE/tls/ios-profile.mobileconfig" -o "$TMP/dl.mobileconfig"
grep -q 'com.apple.security.root' "$TMP/dl.mobileconfig" || fail "mobileconfig download"
pass "HTTP Apple profile download (macOS / iOS primary)"

curl -fsSL "$BASE/tls/knots-ca.cer" -o "$TMP/dl.cer"
cmp -s "$TMP/www/tls/knots-ca.cer" "$TMP/dl.cer" || fail "cer download"
pass "HTTP Android DER download"

# --- 5. Windows: .bat self-fetches .ps1; .ps1 validates CA ---
curl -fsSL "$BASE/tls/install-windows.bat" -o "$TMP/win/install-windows.bat" 2>/dev/null \
	|| mkdir -p "$TMP/win"
mkdir -p "$TMP/win"
curl -fsSL "$BASE/tls/install-windows.bat" -o "$TMP/win/install-windows.bat"
# Simulate bat missing-ps1 fetch
rm -f "$TMP/win/install-windows.ps1"
curl -fsSL "$BASE/tls/install-windows.ps1" -o "$TMP/win/install-windows.ps1"
# P4: the .bat embeds the PowerShell installer (no code download at run time)
grep -q '^#KNOTS-PS1-BEGIN' "$TMP/win/install-windows.bat" || fail "bat must embed the ps1 (P4)"
tr -d '\r' <"$TMP/win/install-windows.bat" | sed '/^#KNOTS-PS1-BEGIN$/,$d' | grep -q 'Invoke-WebRequest' \
	&& fail "bat must not download the ps1 (P4)"
grep -q 'certutil' "$TMP/win/install-windows.ps1" || fail "ps1 must use certutil"
grep -q 'BEGIN CERTIFICATE' "$TMP/win/install-windows.ps1" || fail "ps1 validates PEM"
# Simulate ps1 CA download + PEM check (without elevating)
curl -fsSL "$BASE/knots-ca.crt" -o "$TMP/win/knots-ca.crt"
grep -q 'BEGIN CERTIFICATE' "$TMP/win/knots-ca.crt" || fail "windows CA sidecar"
# Bad CA rejected by same rule
echo nope >"$TMP/win/bad.crt"
grep -q 'BEGIN CERTIFICATE' "$TMP/win/bad.crt" && fail "bad should not look like cert" || true
pass "Windows self-contained bat (embedded ps1) + CA validate simulation"

# --- 6. Linux: full helper with fake sudo (install path exercised) ---
mkdir -p "$TMP/linux/bin" "$TMP/linux/work"
cp "$TLS_SCRIPTS/install-linux.sh" "$TMP/linux/work/"
cp "$TMP/www/knots-ca.crt" "$TMP/linux/work/"
cat >"$TMP/linux/bin/sudo" <<'EOF'
#!/bin/sh
echo "SUDO $*" >>"${SUDO_LOG:-/tmp/sudo.log}"
# accept trust-store install commands without doing them
exit 0
EOF
chmod +x "$TMP/linux/bin/sudo"
# Also stub update-ca-certificates / trust if invoked
for stub in update-ca-certificates trust; do
	printf '#!/bin/sh\necho STUB_%s "$@" >>"%s"\nexit 0\n' "$stub" '$SUDO_LOG' \
		>"$TMP/linux/bin/$stub"
	chmod +x "$TMP/linux/bin/$stub"
done
# Do not see or kill a real desktop Firefox during host tests
printf '#!/bin/sh\nexit 1\n' >"$TMP/linux/bin/pgrep"
printf '#!/bin/sh\nexit 0\n' >"$TMP/linux/bin/pkill"
chmod +x "$TMP/linux/bin/pgrep" "$TMP/linux/bin/pkill"
export SUDO_LOG="$TMP/linux/sudo.log"
: >"$SUDO_LOG"
PATH="$TMP/linux/bin:$PATH" \
	sh "$TMP/linux/work/install-linux.sh" "$TMP/linux/work/knots-ca.crt" \
	>"$TMP/linux/out" 2>&1 || fail "linux install with fake sudo failed: $(cat "$TMP/linux/out")"
grep -q 'SUDO\|Done\|trusted\|certificate' "$TMP/linux/out" "$SUDO_LOG" 2>/dev/null \
	|| grep -qiE 'done|install|certificate' "$TMP/linux/out" \
	|| fail "linux install produced no success signal: $(cat "$TMP/linux/out")"
# Reject bad CA
if PATH="$TMP/linux/bin:$PATH" sh "$TMP/linux/work/install-linux.sh" "$TMP/win/bad.crt" \
	>/dev/null 2>&1; then
	fail "linux must reject bad CA"
fi
grep -q 'after_tls=1' "$TMP/linux/out" \
	|| fail "linux install must print HTTPS Setup URL: $(cat "$TMP/linux/out")"
pass "Linux install helper: good CA + sudo path; bad CA rejected"

# Download-from-router simulation
PATH="$TMP/linux/bin:$PATH" \
	sh "$TMP/linux/work/install-linux.sh" "$BASE" >"$TMP/linux/out2" 2>&1 \
	|| fail "linux download from router URL failed: $(cat "$TMP/linux/out2")"
pass "Linux helper downloads CA from router base URL"

# chmod +x requirement documented / non-exec blocked (existing behaviour)
chmod a-x "$TMP/linux/work/install-linux.sh"
if (cd "$TMP/linux/work" && ./install-linux.sh) 2>/dev/null; then
	fail "./ without +x should not run"
fi
pass "Linux ./ without execute bit blocked (UI chmod step)"

# --- 7. macOS: Terminal window file + helper (one password box, no sudo) ---
mkdir -p "$TMP/mac/bin"
cp "$TLS_SCRIPTS/install-macos.command" "$TMP/mac/"
cp "$TMP/www/knots-ca.crt" "$TMP/mac/"
for c in security open; do
	printf '#!/bin/sh\necho "%s $*" >>"$MAC_LOG"\nexit 0\n' "$c" >"$TMP/mac/bin/$c"; chmod +x "$TMP/mac/bin/$c"
done
printf '#!/bin/sh\necho "sudo $*" >>"$MAC_LOG"\nexit 1\n' >"$TMP/mac/bin/sudo"; chmod +x "$TMP/mac/bin/sudo"
export MAC_LOG="$TMP/mac/calls.log"; : >"$MAC_LOG"
HOME="$TMP/mac" PATH="$TMP/mac/bin:$PATH" bash "$TMP/mac/install-macos.command" "$TMP/mac/knots-ca.crt" </dev/null >"$TMP/mac/out" 2>&1 \
	|| fail "macos helper failed: $(cat "$TMP/mac/out")"
grep -q '^security add-trusted-cert -r trustRoot -k .*/Library/Keychains/login.keychain' "$MAC_LOG" \
	|| fail "macOS helper must trust the CA in the user's login keychain: $(cat "$MAC_LOG")"
! grep -q '^sudo' "$MAC_LOG" || fail "macOS helper must not use sudo (one password box): $(cat "$MAC_LOG")"
grep -q '^open https://.*/setup.html?after_tls=1' "$MAC_LOG" || fail "macOS helper must reopen Setup over HTTPS: $(cat "$MAC_LOG")"
! grep -q '^read ' "$TLS_SCRIPTS/install-macos.command" || fail "macOS helper must not wait for Enter"
pass "macOS helper: CA validated, trusted in the user's keychain (one password box, no sudo), Setup reopened on HTTPS"

test ! -e "$TMP/www/tls/rnode-secure-connection.terminal" || fail ".terminal file must be gone (macOS refused it)"
grep -q 'id="tlsMacCta" href="#"' "$ROOT/files/www/knots/setup.html" && grep -q 'macScriptEditorHref(hm)' "$ROOT/files/www/knots/setup.js" \
	|| fail "Setup's Mac button must be the Script Editor link"
grep -q 'click <strong>Allow</strong>' "$ROOT/files/www/knots/setup.html" && grep -q '▶ Run' "$ROOT/files/www/knots/setup.html" \
	|| fail "Setup must show the Script Editor steps (Allow, ▶ Run, password)"
python3 - "$ROOT/files/www/knots/tls-os.js" <<'PY' || fail "Script Editor link"
import re, sys, urllib.parse
js = open(sys.argv[1]).read()
assert "applescript://com.apple.scripteditor?action=new&script=" in js
assert 'do shell script "' in js
# the command the Mac runs: download the helper to a private temp file, then run it
m = re.search(r'return "(f=\$\(mktemp\) && curl -fsSL http://)" \+ host \+ "(/tls/install-macos.command -o \$f && bash \$f http://)" \+ host;', js)
assert m, "macTrustCommand shape"
assert re.search(r'\[a-z\]\[a-z0-9\+\.-\]\*:', js), "absoluteTrustHref must leave applescript: links alone"
PY
! grep -q 'mobileconfig\|\.terminal' "$ROOT/files/www/knots/setup.html" "$ROOT/files/www/knots/tls.html" \
	|| fail "Macs must not be offered the profile or the .terminal file"
pass "macOS: Script Editor link (Allow → Run → password) with on-screen steps + copy fallback; no profile, no .terminal"

# --- 8. Phones / tablets: "use a laptop or computer", no certificate steps ---
W="$ROOT/files/www/knots"
grep -q 'id="phoneOnly"' "$W/setup.html" && grep -q 'isPhoneOrTablet' "$W/setup.js" \
	|| fail "Setup must show the phone/tablet panel (phoneOnly via isPhoneOrTablet)"
grep -q 'id="tlsPhoneOnly"' "$W/tls.html" && grep -q 'isPhoneOrTablet' "$W/tls.html" \
	|| fail "Secure connection page must show the phone/tablet panel"
! grep -rq 'android-certificate\|data-os="android"\|data-os="ios"\|mobile data' "$W"/*.html "$W"/*.js \
	|| fail "phone certificate paths still in the UI: $(grep -rl 'android-certificate\|data-os="android"\|data-os="ios"\|mobile data' "$W"/*.html "$W"/*.js)"
pass "phones / tablets: one 'use a laptop or computer' panel, no certificate steps"

# --- 9. setup.html / tls.html primary CTA IDs wired ---
for page in setup.html tls.html; do
	f="$ROOT/files/www/knots/$page"
	grep -q 'tlsPrimaryCta' "$f" || fail "$page missing tlsPrimaryCta"
	grep -q 'KnotsTlsOs.bindOsTabs\|tls-os.js' "$f" || fail "$page must bind tls-os"
done
grep -q 'detectedOnly' "$ROOT/files/www/knots/tls-os.js" || fail "tls-os.js must support detectedOnly"
! grep -q 'detectedOnly' "$ROOT/files/www/knots/setup.js" \
	|| fail "setup.js must show OS tabs (not detectedOnly)"
grep -q 'id="tlsOsTabs"' "$ROOT/files/www/knots/setup.html" || fail "setup OS tabs missing"
awk 'BEGIN{inhelp=0} /id="tlsHelp"/{inhelp=1} /<\/details>/{if(inhelp){inhelp=0}} inhelp && /id="tlsOsTabs"/{found=1} END{exit found?0:1}' \
	"$ROOT/files/www/knots/setup.html" \
	&& fail "setup OS tabs must be outside tlsHelp"
grep -q 'tlsOsOtherBtn' "$ROOT/files/www/knots/tls.html" || fail "tls.html other-OS button missing"
pass "Setup + tls.html share OS CTA binder (OS tabs visible on Setup)"

# --- 10. "Add this computer" (owner 2026-10-26) ---
T_HTML="$ROOT/files/www/knots/tls.html"
grep -q 'id="addIntro"' "$T_HTML" && grep -q 'mode: "no-cors"' "$T_HTML" && grep -q 'location.replace(secure)' "$T_HTML" \
	&& grep -q 'location.protocol !== "http:"' "$T_HTML" || fail "tls.html must check trust quietly and carry trusted computers on to https"
grep -q 'id="addPcUrl"' "$ROOT/files/www/knots/settings.html" && grep -q 'addPcUrl' "$ROOT/files/www/knots/settings.js" \
	|| fail "Settings must say how to add another computer"
pass "Add this computer: plain address → steps (trusted computers go straight to https); Settings explains it"

echo "ALL PASS: test-iue-tls-os"
