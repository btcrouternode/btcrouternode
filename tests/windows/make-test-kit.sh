#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Build bin/windows-test-kit.zip — run the Windows CA installer on a real
# Windows PC in -CheckOnly mode (verifies + prints fingerprint, installs
# NOTHING, no elevation). Copy the zip over RDP, unzip, double-click
# run-tests.bat, send back results.txt.  Review P4 (2026-10-11).
#   Optional: ROUTER_CA=/path/to/router-knots-ca.crt (the real router's CA)
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUT="$ROOT/bin/windows-test-kit"
rm -rf "$OUT" "$OUT.zip"; mkdir -p "$OUT/certs"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

python3 -I "$ROOT/build/gen-install-windows-bat.py" >/dev/null
cp "$ROOT/files/www/knots/tls/install-windows.bat" "$ROOT/files/www/knots/tls/install-windows.ps1" "$OUT/"

KNOTS_TLS_DIR="$W/good" KNOTS_WWW_DIR="$W/gw" KNOTS_LAN_IP=192.168.1.254 \
	sh "$ROOT/files/usr/libexec/knots/node-ui-tls.sh" node-router >/dev/null 2>&1
cp "$W/good/ca.pem" "$OUT/certs/good.crt"
NC='permitted;DNS:node-router,permitted;DNS:knots-router,permitted;DNS:localhost,permitted;DNS:local,permitted;DNS:lan,permitted;IP:10.0.0.0/255.0.0.0,permitted;IP:172.16.0.0/255.240.0.0,permitted;IP:192.168.0.0/255.255.0.0,permitted;IP:127.0.0.0/255.0.0.0'
mk() { # NAME CN EXT
	printf '[req]\ndistinguished_name=dn\nx509_extensions=v\nprompt=no\n[dn]\nCN=%s\n[v]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n%s\n' "$2" "$3" >"$W/$1.cnf"
	openssl req -x509 -nodes -newkey rsa:2048 -keyout "$W/$1.key" -out "$OUT/certs/$1.crt" -days 30 -config "$W/$1.cnf" 2>/dev/null
}
mk plain "Knots Appliance CA" ""
mk extra "Knots Appliance CA" "nameConstraints=critical,$NC,permitted;DNS:example.com"
mk subj  "Evil Root CA"       "nameConstraints=critical,$NC"
mk noncrit "Knots Appliance CA" "nameConstraints=$NC"
if [ -n "${ROUTER_CA:-}" ] && [ -f "$ROUTER_CA" ]; then cp "$ROUTER_CA" "$OUT/certs/router.crt"; fi

{
for c in good router plain extra subj noncrit; do
	[ -f "$OUT/certs/$c.crt" ] || continue
	exp=REFUSE; case "$c" in good|router) exp=ACCEPT ;; esac
	printf '%-8s expect %-6s sha256 %s\n' "$c" "$exp" "$(openssl x509 -in "$OUT/certs/$c.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
done
} >"$OUT/EXPECTED.txt"

cat >"$W/run-tests.bat" <<'BAT'
@echo off
REM Knots Windows CA installer test kit (review P4). Installs NOTHING:
REM every case runs with -CheckOnly. Writes results.txt next to this file.
setlocal EnableDelayedExpansion
cd /d "%~dp0"
set "OUT=%~dp0results.txt"
echo Knots Windows installer test kit > "%OUT%"
powershell.exe -NoProfile -Command "'PowerShell ' + $PSVersionTable.PSVersion.ToString(); [Environment]::OSVersion.VersionString; (Get-Culture).Name" >> "%OUT%" 2>&1
for %%C in (good router plain extra subj noncrit) do (
  if exist "certs\%%C.crt" (
    echo ===== CASE %%C ===== >> "%OUT%"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-windows.ps1" -Router http://127.0.0.1:9 -CaFile "%~dp0certs\%%C.crt" -CheckOnly >> "%OUT%" 2>&1
    echo EXITCODE %%C=!errorlevel! >> "%OUT%"
  )
)
echo ===== CASE bat-sidecar (double-click path, router unreachable, knots-ca.crt next to the .bat) ===== >> "%OUT%"
copy /y "certs\good.crt" "knots-ca.crt" >nul
echo.| call "%~dp0install-windows.bat" http://127.0.0.1:9 -CheckOnly >> "%OUT%" 2>&1
del /q "knots-ca.crt" >nul 2>&1
echo ===== END ===== >> "%OUT%"
echo Done. Please send back: %OUT%
pause
BAT
python3 -I - "$W/run-tests.bat" "$OUT/run-tests.bat" "$OUT/EXPECTED.txt" <<'PY'
import sys
for src, dst in ((sys.argv[1], sys.argv[2]), (sys.argv[3], sys.argv[3])):
    t = open(src, encoding="ascii").read().replace("\r\n", "\n").replace("\n", "\r\n")
    open(dst, "wb").write(t.encode("ascii"))
PY
( cd "$ROOT/bin" && python3 -I -m zipfile -c windows-test-kit.zip windows-test-kit/ )
echo "kit: $OUT.zip"
cat "$OUT/EXPECTED.txt"
