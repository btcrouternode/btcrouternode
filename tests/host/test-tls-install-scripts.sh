#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Host validation for TLS install scripts (N13 / U17). Uses real CA when provided.
# Usage: tests/host/test-tls-install-scripts.sh [/path/to/knots-ca.crt]
set -e
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
TLS="$ROOT/files/www/knots/tls"
CA="${1:-}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

sh -n "$TLS/install-linux.sh" || fail "linux syntax"
grep -q 'ROUTER="http://rnode.local"' "$TLS/install-linux.sh" \
	|| fail "linux installer default must be http://rnode.local"
grep -q 'http://rnode.local' "$TLS/install-windows.ps1" \
	|| fail "windows installer default must be rnode.local"
grep -q 'http://rnode.local' "$TLS/install-windows.bat" \
	|| fail "windows bat default must be rnode.local"
grep -q 'ROUTER="http://rnode.local"' "$TLS/install-macos.command" \
	|| fail "macos installer default must be http://rnode.local"
# Linux installer must reopen HTTPS Setup after it closes Firefox (N13 / U17)
grep -q 'reopen_setup_https' "$TLS/install-linux.sh" || fail "linux must reopen browser"
grep -q 'after_tls=1' "$TLS/install-linux.sh" || fail "linux reopen must use after_tls=1"
grep -q 'ff_closed_by_us' "$TLS/install-linux.sh" || fail "linux must track Firefox close"
grep -q 'sh "\$f" http://' "$ROOT/files/www/knots/setup.js" \
	|| fail "Linux one-liner must pass router URL into the installer"
grep -q 'Firefox closes for a moment and reopens on the secure Setup page by itself' "$ROOT/files/www/knots/setup.html" \
	|| fail "setup.html must say Firefox reopens on HTTPS"
bash -n "$TLS/install-macos.command" || fail "macos syntax"
grep -q 'certutil' "$TLS/install-windows.ps1" || fail "windows ps1"
grep -q 'install-windows.ps1' "$TLS/install-windows.bat" || fail "windows bat"
# Windows PowerShell 5.1: "$(subexpr):8443" is a scope; "} else {" then UnexpectedToken
if grep -E '\$\([^)]*\):[0-9]' "$TLS/install-windows.ps1" >/dev/null; then
	fail "windows ps1 must not use \$(...):port inside a double-quoted string"
fi
# No UTF-8 curly quotes / dashes in the script body (PS 5.1 reads IWR as ANSI)
if LC_ALL=C grep -n '[^[:print:][:space:]]' "$TLS/install-windows.ps1" >/dev/null; then
	fail "windows ps1 must be ASCII (Windows PowerShell 5.1 has no UTF-8 default)"
fi
grep -q 'after_tls=1' "$TLS/install-windows.ps1" || fail "windows must reopen HTTPS Setup"
grep -q 'function Reopen-SetupHttps' "$TLS/install-windows.ps1" || fail "windows reopen helper missing"
awk '/if \(-not \$isAdmin\)/,/^}$/' "$TLS/install-windows.ps1" | grep -q Reopen-SetupHttps \
	|| fail "windows must reopen Setup in the unelevated process (not the UAC child)"
grep -q 'fully quit your browser' "$TLS/install-windows.bat" \
	&& fail "windows bat must not tell the user to quit and retype the URL"
grep -q 'if not exist' "$TLS/install-windows.bat" \
	&& fail "windows bat must re-download install-windows.ps1 every run"

# .111 (owner 2026-10-25): Linux = the Ubuntu/Debian/Mint package (App Center)
# or the Terminal command; no "make the download executable" steps any more.
grep -q 'rnode-secure-connection.deb' "$ROOT/files/www/knots/setup.html" || fail "setup.html must offer the Linux package"
! grep -q 'chmod +x' "$ROOT/files/www/knots/setup.html" "$ROOT/files/www/knots/tls.html" \
	|| fail "no chmod +x steps for customers"
# Browser download Allow/Save (Firefox)
grep -qi 'Firefox' "$ROOT/files/www/knots/setup.html" || fail "setup must mention Firefox download Allow"
grep -qi 'Allow' "$ROOT/files/www/knots/setup.html" || fail "setup must teach Allow/Save download"
grep -q 'tlsDownloadTip' "$ROOT/files/www/knots/setup.html" || fail "download tip callout missing"
# No stale "blue button" (accent is orange)
! grep -qi 'blue button' "$ROOT/files/www/knots/setup.html" \
	|| fail "setup.html still says blue button"
! grep -qi 'blue button' "$ROOT/files/www/knots/tls.html" \
	|| fail "tls.html still says blue button"
grep -qiE 'orange (<strong>)?Enable Secure Connection' "$ROOT/files/www/knots/setup.html" \
	|| fail "setup should say orange Enable Secure Connection"
grep -q 'Bitcoin Node' "$ROOT/files/www/knots/setup.html" || fail "setup brand"
# Zero-tech: welcome + password numbered guidance
grep -q 'Continue' "$ROOT/files/www/knots/setup.html" || fail "welcome CTA"
grep -qi 'at least' "$ROOT/files/www/knots/setup.html" || fail "password min length guidance"
grep -q 'data-pw-toggle' "$ROOT/files/www/knots/setup.html" || fail "password Show/Hide toggle missing"
grep -q 'pw-match' "$ROOT/files/www/knots/setup.js" || fail "password match highlight missing"
grep -q 'bindPasswordMatch' "$ROOT/files/www/knots/setup.js" || fail "bindPasswordMatch missing"
grep -q '\.pw-match' "$ROOT/files/www/knots/app.css" || fail "pw-match CSS missing"
pass "syntax and UI steps"

cp "$TLS/install-linux.sh" "$TMP/"
chmod a-x "$TMP/install-linux.sh"
if (cd "$TMP" && ./install-linux.sh) 2>/dev/null; then
  fail "./ without +x should not run"
fi
pass "./ without execute bit is blocked (chmod required)"

if [ -n "$CA" ] && [ -f "$CA" ]; then
  cp "$CA" "$TMP/knots-ca.crt"
  openssl x509 -in "$TMP/knots-ca.crt" -noout -subject >/dev/null || fail "CA parse"
  # Bad file rejected
  echo nope >"$TMP/bad.crt"
  if (cd "$TMP" && sh install-linux.sh ./bad.crt) 2>/dev/null; then
    fail "bad CA should fail"
  fi
  pass "bad CA rejected"
  # Pre-sudo path: HTTP download
  python3 -m http.server 0 --bind 127.0.0.1 --directory "$TMP" >"$TMP/http.log" 2>&1 &
  HPID=$!
  sleep 0.3
  # discover port from log is hard; use fixed
  kill "$HPID" 2>/dev/null || true
  python3 -m http.server 18765 --bind 127.0.0.1 --directory "$TMP" >"$TMP/http.log" 2>&1 &
  HPID=$!
  sleep 0.4
  curl -fsSL "http://127.0.0.1:18765/knots-ca.crt" -o "$TMP/dl.crt"
  kill "$HPID" 2>/dev/null || true
  cmp -s "$TMP/knots-ca.crt" "$TMP/dl.crt" || fail "http download mismatch"
  pass "HTTP CA download"
  # Script exits 1 without interactive sudo (expected on CI hosts)
  set +e
  (cd "$TMP" && sh install-linux.sh ./knots-ca.crt) >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "expected non-zero without sudo tty"
  pass "script fails closed without sudo (rc=$rc)"
else
  echo "SKIP live CA tests (pass path to knots-ca.crt to enable)"
fi

echo "ALL PASS"
