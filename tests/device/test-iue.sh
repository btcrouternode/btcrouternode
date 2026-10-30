#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Device IUE verify (U17 / U19 / N13) — Setup API + TLS download paths.
# Short serial commands (busybox wget has no -S). Does not wipe M.2.
# Assumes factory/lab password knotsnode21 (R13) — fails after a completed
# retail Setup; reset or re-provision first.
# Usage: SERIAL=/dev/ttyUSB0 tests/device/test-iue.sh
set -euo pipefail
SERIAL="${SERIAL:?set SERIAL=/dev/ttyUSB0 (X4: device tests drive a real unit)}"
python3 - "$SERIAL" <<'PY'
import os, re, time, sys, serial

port = sys.argv[1]

class SerialNoModem(serial.Serial):
    def _update_dtr_state(self): return
    def _update_rts_state(self): return

ser = SerialNoModem()
ser.port = port
ser.baudrate = 115200
ser.timeout = 0.35
ser.write_timeout = 30
ser.xonxoff = False
ser.rtscts = False
ser.dsrdtr = False
ser.open()
try:
    import termios, subprocess
    attrs = termios.tcgetattr(ser.fd)
    attrs[2] &= ~termios.HUPCL
    termios.tcsetattr(ser.fd, termios.TCSANOW, attrs)
    subprocess.run(["stty", "-F", port, "-hupcl", "clocal"],
                   check=False, capture_output=True)
except Exception:
    pass
time.sleep(0.2)
try:
    ser.reset_input_buffer()
except Exception:
    pass

def read_until(token, timeout=45.0):
    buf = ""
    end = time.time() + timeout
    while time.time() < end:
        chunk = ser.read(8192)
        if chunk:
            t = chunk.decode("utf-8", "replace")
            buf += t
            if re.search(rf"(?m)^{re.escape(token)}\r?$", buf):
                time.sleep(0.1)
                e = ser.read(8192)
                if e:
                    buf += e.decode("utf-8", "replace")
                return buf
        else:
            time.sleep(0.03)
    return buf

# X2 (review 2026-10-11): the serial console ECHOES every command, so a marker
# like `echo FOO_OK` (or a `;echo TOKEN` terminator) always appeared in the
# output even when the command failed. Split each echoed word with '' — the
# shell prints FOO_OK, the echoed command line shows FO''O_OK.
import re as _x2re
def quote_markers(s):
    return _x2re.sub(r"\becho (\w)(\w+)", r"echo \1''\2", s)

def cmd(line, timeout=45.0):
    """Keep line short — serial wraps ~70–80 cols."""
    if len(line) > 160:
        raise ValueError(f"cmd too long ({len(line)}): {line[:60]}…")
    tok = f"T{int(time.time()) % 100000}X"
    print(">>>", line, flush=True)
    ser.write((quote_markers(f"{line};echo {tok}") + "\n").encode())
    ser.flush()
    out = read_until(tok, timeout)
    print(out[-500:] if len(out) > 500 else out, flush=True)
    return out

ser.write(b"\r\n")
time.sleep(0.4)
buf = ser.read(4096).decode("utf-8", "replace")
if "login:" in buf.lower():
    ser.write(b"root\n")
    time.sleep(0.5)
    b2 = ser.read(4096).decode("utf-8", "replace")
    if "assword" in b2.lower():
        ser.write((os.environ.get("SERIAL_PASS") or "knotsnode21").encode() + b"\n")
        time.sleep(1.0)
        ser.read(8192)

fails = []

def check(name, ok, detail=""):
    if ok:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} {detail}")
        fails.append(name)

# mbedTLS curl cannot parse the restricted CA (see smoke.sh): HTTPS via openssl
cmd(r"""hs(){ printf 'GET %s HTTP/1.0\r\nHost: rnode.local\r\n\r\n' $1|openssl s_client -quiet -connect 127.0.0.1:443 -CAfile /etc/knots/tls/ca.pem 2>/dev/null;}""")
out = cmd("hs '/api/setup?action=status' | sed 1,/^.$/d | head -c 800")
check("api_setup_status", '"ok":true' in out.replace(" ", "") or '"ok": true' in out)

out = cmd("test -f /www/knots/setup.html -a -f /www/knots/tls-os.js && echo IUE_OK")
check("iue_assets", "IUE_OK" in out)

out = cmd("openssl x509 -in /www/knots/knots-ca.crt -noout -subject >/dev/null && echo CA_OK")
check("published_ca", "CA_OK" in out)

# Headers via curl (busybox wget lacks -S) — CA stays on HTTP
out = cmd("curl -sI http://127.0.0.1/knots-ca.crt | head -15")
check("ca_disposition", "attachment" in out.lower() or "content-disposition" in out.lower(), out[-200:])

# U17/N13 — while Setup is incomplete, :80 / stays on HTTP (setup.html), never HTTPS.
out = cmd("curl -sI http://127.0.0.1/ | head -12")
check("http_iue_landing", "302" in out and "setup.html" in out, out[-120:])
check("http_iue_not_https", "https://" not in out.lower(), out[-120:])

# LuCI :8080 → :8443
out = cmd("curl -sI http://127.0.0.1:8080/ | head -12")
check("luci_http_redirect", " 302" in out and " 301" not in out, out[-120:])
check("luci_https_8443", "8443" in out, out[-120:])

assets = [
    "/tls/install-linux.sh",
    "/tls/install-windows.bat",
    "/tls/install-windows.ps1",
    "/tls/install-macos.command",
    "/tls/ios-profile.mobileconfig",
    "/tls/knots-ca.cer",
]
for path in assets:
    # Set path in shell env first so wget line stays short (serial wrap ~70 cols)
    cmd(f"P={path}")
    out = cmd("wget -qO /tmp/iue.bin http://127.0.0.1$P; echo W:$?")
    check(f"dl{path}", "W:0" in out, out[-80:])
    out = cmd("wc -c </tmp/iue.bin")
    nums = re.findall(r"(?m)^(\d+)\r?$", out)
    size = int(nums[-1]) if nums else 0
    check(f"size{path}", size > 50, f"size={size}")

out = cmd("grep -q com.apple.security.root /www/knots/tls/ios-profile.mobileconfig && echo MC_OK")
check("mobileconfig_profile", "MC_OK" in out)

# Setup mutations need POST (UAT-SEC-GET); :80 is the IUE path
out = cmd("curl -s -d x=1 'http://127.0.0.1/api/setup?action=complete' | head -c 300")
if '"ok":true' in out.replace(" ", ""):
    check("complete_ok_or_gated", True)
else:
    check(
        "complete_requires_prereqs",
        any(x in out for x in ("locale_required", "password_required", "LAN", "lan_only", "forbidden")),
        out[-160:],
    )

out = cmd("curl -s -d 'password=knotsnode21&password2=knotsnode21' 'http://127.0.0.1/api/setup?action=password' | head -c 250")
check("factory_password_forbidden", "factory_forbidden" in out or '"ok":true' not in out.replace(" ", ""))

out = cmd("curl -s -d 'password=short&password2=short' 'http://127.0.0.1/api/setup?action=password' | head -c 200")
check("password_too_short", "too_short" in out)

out = cmd("curl -s -d 'ssid=rnode&key=short&country=AU' 'http://127.0.0.1/api/setup?action=wifi' | head -c 250")
check("wifi_key_too_short", "wifi_failed" in out or "no_radio" in out)

out = cmd("grep -c data-os= /www/knots/setup.html")
nums = re.findall(r"(?m)^(\d+)\r?$", out)
n = int(nums[-1]) if nums else 0
check("setup_os_tabs", n >= 10, f"count={n}")

out = cmd("grep -E 'data-step=\"1\".*id=\"stepTls\"|id=\"stepTls\".*data-step=\"1\"' /www/knots/setup.html | head -1")
check("tls_first_step", "stepTls" in out and 'data-step="1"' in out)

out = cmd("grep -q 'bindOsTabs' /www/knots/setup.js && grep -q 'Enable Secure Connection' /www/knots/setup.html && echo TLS_UX_OK")
check("tls_os_only_ux", "TLS_UX_OK" in out)

out = cmd("uci get system.@system[0].hostname")
check("hostname_node_router", "node-router" in out)

ser.close()
if fails:
    print("FAILED:", ", ".join(fails))
    sys.exit(1)
print("ALL PASS: test-iue device")
PY
