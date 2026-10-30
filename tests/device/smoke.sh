#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# On-device smoke via USB serial — read-only / negative. Never wipes M.2.
set -euo pipefail
SERIAL="${SERIAL:?set SERIAL=/dev/ttyUSB0 (X4: device tests drive a real unit)}"
python3 - "$SERIAL" <<'PY'
import serial, time, re, sys, termios, subprocess
port = sys.argv[1]
class SerialNoModem(serial.Serial):
    def _update_dtr_state(self): return
    def _update_rts_state(self): return
ser = SerialNoModem()
ser.port, ser.baudrate, ser.timeout = port, 115200, 0.25
ser.write_timeout = 30
ser.xonxoff = ser.rtscts = ser.dsrdtr = False
ser.open()
try:
    attrs = termios.tcgetattr(ser.fd)
    attrs[2] &= ~termios.HUPCL
    termios.tcsetattr(ser.fd, termios.TCSANOW, attrs)
    subprocess.run(["stty", "-F", port, "-hupcl", "clocal"],
                   check=False, capture_output=True)
except Exception:
    pass
time.sleep(0.2)

def drain(t=2.0):
    end = time.time() + t
    buf = b""
    while time.time() < end:
        c = ser.read(8192)
        if c:
            buf += c
            end = time.time() + 0.35
        else:
            time.sleep(0.02)
    return buf.decode("utf-8", "replace")

# X2 (review 2026-10-11): the serial console ECHOES every command, so a marker
# like `echo FOO_OK` (or a `;echo TOKEN` terminator) always appeared in the
# output even when the command failed. Split each echoed word with '' — the
# shell prints FOO_OK, the echoed command line shows FO''O_OK.
import re as _x2re
def quote_markers(s):
    return _x2re.sub(r"\becho (\w)(\w+)", r"echo \1''\2", s)

def cmd(s, w=8):
    for _ in range(2):
        ser.write(b"\x03"); time.sleep(0.05)
    while ser.in_waiting:
        ser.read(ser.in_waiting)
    ser.write((quote_markers(s) + "\r\n").encode()); ser.flush()
    return drain(w)


# Console login (files/etc/uci-defaults/88-knots-ttylogin): the serial console
# asks for the router password. SERIAL_PASS (default: factory knotsnode21).
import os
SERIAL_PASS = (os.environ.get("SERIAL_PASS") or "knotsnode21")
def read_until(tokens, t):
    end = time.time() + t; acc = ""
    while time.time() < end:
        c = ser.read(4096)
        if c:
            acc += c.decode("utf-8", "replace")
            if any(k in acc.lower() for k in tokens):
                time.sleep(0.3); acc += ser.read(4096).decode("utf-8", "replace"); break
    return acc
def console_login():
    ser.write(b"\r\n"); out = read_until(["login:", "# "], 4)
    if "login:" in out.lower():
        ser.write(b"root\r\n"); read_until(["assword"], 5)
        ser.write(SERIAL_PASS.encode() + b"\r\n"); out = read_until(["# ", "incorrect"], 15)
        if "incorrect" in out.lower():
            sys.exit("console login failed — set SERIAL_PASS to this router's password")
    return out

# T-CON-1: log out — the console must ask for a login, refuse a wrong password,
# then accept the router password.
console_login(); drain(1)
ser.write(b"exit\r\n"); con_out = read_until(["activate", "login:"], 10)
if "login:" not in con_out.lower():   # askconsole: "Please press Enter to activate"
    ser.write(b"\r\n"); con_out += read_until(["login:"], 10)
con_asked = "login:" in con_out.lower()
ser.write(b"root\r\n"); read_until(["assword"], 5)
ser.write(b"not-the-password\r\n"); con_bad = read_until(["incorrect"], 15)
con_refused = "incorrect" in con_bad.lower()
read_until(["login:"], 10)
console_login(); drain(1)
cmd("export PAGER=cat", 2)
con_shell = "CON_SHELL_OK" in cmd("echo CON_SHELL_OK", 3)
fails = []
blob = ""

def check(name, ok, detail=""):
    if ok:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} {detail}")
        fails.append(name)

parts = [
    "uci get network.lan.ipaddr; uci get dhcp.lan.start; uci get dhcp.lan.limit",
    "cat /etc/knots/product_version; grep -q ' /mnt/bitcoin ' /proc/mounts && echo MOUNTED || echo UNMOUNTED",
    "lxc-info -n knots 2>/dev/null | head -5",
    "test -x /usr/libexec/knots/led-status.sh && /usr/libexec/knots/led-status.sh; echo LEDSTATE=$(cat /tmp/knots/led.state 2>/dev/null); echo TRIG=$(cat /sys/class/leds/green:status/trigger 2>/dev/null | tr -d '\\n' | head -c 120)",
    "nginx -t -c /etc/nginx/uci.conf 2>&1 | tail -3; pidof nginx >/dev/null && echo NGX_UP || echo NGX_DOWN; wget -qO- -T 3 http://127.0.0.1/api/alive; echo",
    # The router's curl uses mbedTLS, which cannot parse the restricted CA's
    # Name Constraints (handshake error -0x2562; browsers/openssl are fine):
    # on-device HTTPS goes through openssl s_client, which also verifies.
    "hs(){ printf 'GET %s HTTP/1.0\\r\\nHost: rnode.local\\r\\n\\r\\n' \"$1\"|openssl s_client -quiet -connect 127.0.0.1:443 -CAfile /etc/knots/tls/ca.pem -verify_return_error 2>/dev/null;}; echo HS_DEF",
    "hs /api/status | sed 1,/^.$/d | head -c 1500; echo",
    "echo | openssl s_client -connect 127.0.0.1:443 -CAfile /etc/knots/tls/ca.pem 2>&1 | grep 'Verify return'",
    "uci get firewall.knots_p2p_dnat.dest_port; uci get firewall.reject_wan_luci.dest_port",
    "test ! -e /usr/libexec/knots/storage-wipe.sh && echo NO_WIPE_OK; knots-storage wipe 2>&1 | head -2; echo",
]
for p in parts:
    blob += cmd(p, 10) + "\n"

print("--- raw ---")
print(blob[-4500:])

check("T-CON-1", con_asked and con_refused and con_shell,
      f"asked={con_asked} refused={con_refused} shell={con_shell}")
# DHCP start: 100 at factory, whatever Setup chose afterwards (UAT Guided: 110)
check("T-LAN-1", "192.168.1.254" in blob and re.search(r"(^|\n)([2-9]|[1-9]\d|1\d\d|2[0-4]\d)\r?\n", blob) is not None)
check("T-VER-1", re.search(r"24\.10\.\d+\.\d+", blob) is not None)
check("T-STO-4", re.search(r"(^|\n)MOUNTED\r?(\n|$)", blob) is not None)
check("T-LED-1", re.search(r"LEDSTATE=(syncing|synced|booting|error)", blob) is not None)
check("T-NGX-T-live", "test is successful" in blob and "NGX_UP" in blob and '"alive":true' in blob)
check("T-UI-2", "verification_progress" in blob and "product_version" in blob)
check("T-TLS-1", "code: 0 (ok)" in blob)
check("T-FW-1", "8333" in blob and ("80 443" in blob or "8080 8443" in blob))
check("T-STO-3a-live", "NO_WIPE_OK" in blob and "refusing" in blob.lower())
check("T-NODE-1", "RUNNING" in blob or "21.21.21.21" in blob)

ser.close()
if fails:
    print("FAILED:", ", ".join(fails))
    sys.exit(1)
print("All device smoke checks passed")
PY
