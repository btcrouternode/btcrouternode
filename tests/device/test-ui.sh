#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Device UI verify: Knots HTTP landing, segmented nav, LuCI auth required, return link
# Assumes factory/lab password knotsnode21 (R13) — fails after a completed
# retail Setup; reset or re-provision first.
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

def cmd(s, w=14):
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

console_login(); drain(1)
cmd("export PAGER=cat", 2)
fails = []
blob = ""

def check(name, ok, detail=""):
    if ok:
        print(f"PASS {name}")
    else:
        print(f"FAIL {name} {detail}")
        fails.append(name)

parts = [
    # Clear sessions before auth tests
    "rm -rf /tmp/luci-sessions; mkdir -p /tmp/luci-sessions; echo SESS_CLEARED",
    # X3 (review 2026-10-11): :80 / answers 302 (never 301 — F135) to HTTPS
    # once Setup is complete; Node Status itself is served on :443.
    # The router's curl uses mbedTLS, which cannot parse the restricted CA's
    # Name Constraints (handshake error -0x2562; browsers/openssl are fine):
    # on-device HTTPS goes through openssl s_client, which also verifies.
    "hs(){ printf 'GET %s HTTP/1.0\\r\\nHost: rnode.local\\r\\n\\r\\n' \"$1\"|openssl s_client -quiet -connect 127.0.0.1:443 -CAfile /etc/knots/tls/ca.pem -verify_return_error 2>/dev/null;}; echo HS_DEF",
    "curl -s -o /dev/null -w 'HTTP_UI:%{http_code}\\n' --max-time 8 http://127.0.0.1/; hs / >/tmp/https-ui; head -1 /tmp/https-ui",
    # Segmented nav + theme (U1b); Storage hidden (U8); wallet switch warn (U7a)
    "grep -q nav-item /www/knots/shell.js && echo NAV_ITEM_OK; grep -q topnav-primary /www/knots/app.css && echo NAV_SEG_OK",
    "grep -q 'label: \"Storage\"' /www/knots/shell.js && echo STORAGE_NAV_BAD || echo STORAGE_NAV_HIDDEN",
    "grep -q wallet-switch-warn /www/knots/node.html && echo U7A_HTML_OK; grep -q WALLET_ACK /usr/libexec/knots/node-impl.sh && echo U7A_API_OK; grep -q wallet_present /usr/libexec/knots/node-impl.sh && echo U7A_PROBE_OK",
    "test -f /www/knots/theme.js && echo THEME_JS_OK; grep -q prefers-color-scheme /www/knots/theme.js && echo THEME_SYS_OK; grep -q 'data-theme=\"dark\"' /www/knots/app.css && echo THEME_DARK_OK; grep -q theme-toggle /www/knots/shell.js && echo THEME_UI_OK; grep -q theme.js /www/knots/index.html && echo THEME_HTML_OK",
    # Pre-login chooser uses HTTP dashboard link + auth messaging
    "grep -q 'https://rnode.local/' /www/luci-entry.html && echo ENTRY_HTTP_OK; grep -qi 'Admin login is required' /www/luci-entry.html && echo ENTRY_AUTH_MSG_OK; grep -q 'Continue to LuCI login' /www/luci-entry.html && echo ENTRY_LUCI_OK",
    # LuCI is HTTPS-only on :8443 (:8080 only redirects) — requests go through
    # openssl (hq PORT METHOD PATH [BODY] [COOKIE]); mbedTLS curl cannot
    # parse the restricted CA. LuCI answers a good login with 302 + sysauth.
    "hq(){ b=\"$4\"; { printf '%s %s HTTP/1.0\\r\\nHost: rnode.local\\r\\n' \"$2\" \"$3\"; [ -z \"$5\" ] || printf 'Cookie: %s\\r\\n' \"$5\"; [ -z \"$b\" ] || printf 'Content-Type: application/x-www-form-urlencoded\\r\\nContent-Length: %s\\r\\n' ${#b}; printf '\\r\\n%s' \"$b\"; } | openssl s_client -quiet -connect 127.0.0.1:$1 -CAfile /etc/knots/tls/ca.pem 2>/dev/null; }; echo HQ_DEF",
    # Unauthenticated LuCI admin MUST be 403
    "echo NOAUTH:$(hq 8443 GET /cgi-bin/luci/admin/status/overview | head -1 | cut -d' ' -f2)",
    # Wrong password rejected
    "hq 8443 POST /cgi-bin/luci/ 'luci_username=root&luci_password=wrongpass' >/tmp/bad; echo BADPASS:$(head -1 /tmp/bad | cut -d' ' -f2)",
    # Correct password accepted (session cookie issued)
    "hq 8443 POST /cgi-bin/luci/ 'luci_username=root&luci_password=knotsnode21' >/tmp/ok; echo OKPASS:$(head -1 /tmp/ok | cut -d' ' -f2); grep -qi '^set-cookie: sysauth' /tmp/ok && echo SESS_COOKIE_OK",
    # Login page checks (short cmds — serial wraps long lines)
    "hq 8443 GET /cgi-bin/luci/ >/tmp/login.html; echo LOGIN_FETCHED",
    "grep -q knots-login-return /tmp/login.html && echo LOGIN_BAR_OK",
    "grep -q modal.login /tmp/login.html && echo LOGIN_PLACE_OK",
    "grep -q 'Node Dashboard' /tmp/login.html && echo LOGIN_LABEL_OK",
    "grep -q 'rnode.local' /tmp/login.html && echo LOGIN_HREF_OK",
    "grep -q 'font-size: 16px' /tmp/login.html && echo LOGIN_SIZE_OK",
    "grep -q 'font-weight: 700' /tmp/login.html && echo LOGIN_BOLD_OK",
    "grep -q offsetWidth /tmp/login.html && echo LOGIN_CENTER_OK",
    "grep -q knots-return-bar /tmp/login.html && echo LOGIN_TOPBAR_BAD || echo LOGIN_TOPBAR_GONE",
    # Menu / controller / CSS embed
    "grep -q 'Node Dashboard' /usr/share/luci/menu.d/node-dashboard.json && echo MENU_TITLE_OK",
    "grep -q action_exit /usr/share/luci/menu.d/node-dashboard.json && echo MENU_EXIT_OK",
    "test -f /usr/share/ucode/luci/controller/admin/node_dashboard.uc && echo MENU_CTRL_OK",
    "test ! -f /usr/lib/lua/luci/view/knots_dashboard.htm && echo NO_LUA_HTM_OK",
    "grep -q knots-return-css-begin /www/luci-static/bootstrap/cascade.css && echo CSS_INLINE_OK",
    # Node Dashboard: login, then 302 logout+redirect, then session dead
    "hq 8443 POST /cgi-bin/luci/ 'luci_username=root&luci_password=knotsnode21' >/tmp/ok2; C=$(grep -i '^set-cookie: sysauth' /tmp/ok2 | head -1 | sed 's/^[^:]*: //; s/;.*//'); echo OK2:${#C}",
    "hq 8443 GET /cgi-bin/luci/admin/node-dashboard '' \"$C\" >/tmp/ndh; echo ND:$(head -1 /tmp/ndh | cut -d' ' -f2)",
    "grep -i '^location:' /tmp/ndh | grep -qi 'rnode.local' && echo ND_REDIR_OK; head -5 /tmp/ndh",
    "echo POSTLOGOUT:$(hq 8443 GET /cgi-bin/luci/admin/status/overview '' \"$C\" | head -1 | cut -d' ' -f2)",
    # Node UI over HTTPS: Node Status after Setup, the Setup resume during it
    "[ -f /etc/knots/setup-complete ] && echo SETUP_DONE || echo SETUP_IUE; hs / >/tmp/dash; echo DASH:$(head -1 /tmp/dash | cut -d' ' -f2); grep -ci '^location:.*setup.html' /tmp/dash",
    # After clear, auth required again
    "rm -rf /tmp/luci-sessions; mkdir -p /tmp/luci-sessions; echo AFTER:$(hq 8443 GET /cgi-bin/luci/admin/status/overview | head -1 | cut -d' ' -f2)",
]
for i, p in enumerate(parts):
    wait = 30 if "OK2:" in p or "OKPASS:" in p or "BADPASS:" in p or "admin/node-dashboard" in p else 12
    blob += cmd(p, wait) + "\n"

print("--- raw ---")
print(blob[-6000:])

# HTTPS / is Node Status (200) after Setup, or the after_tls resume (302) during it
check("T-UI-HTTP-LANDING", "HTTP_UI:302" in blob and re.search(r"HTTP/1\.[01] (200|302)", blob) is not None and "HTTP_UI:301" not in blob)
check("T-UI-NAV-SEGMENTS", "NAV_ITEM_OK" in blob and "NAV_SEG_OK" in blob)
check("T-UI-STORAGE-HIDDEN", "STORAGE_NAV_HIDDEN" in blob)
check(
    "T-UI-U7A-SWITCH",
    "U7A_HTML_OK" in blob and "U7A_API_OK" in blob and "U7A_PROBE_OK" in blob,
)
check(
    "T-UI-THEME",
    "THEME_JS_OK" in blob
    and "THEME_SYS_OK" in blob
    and "THEME_DARK_OK" in blob
    and "THEME_UI_OK" in blob
    and "THEME_HTML_OK" in blob,
)
check(
    "T-UI-LUCI-ENTRY",
    "ENTRY_HTTP_OK" in blob and "ENTRY_AUTH_MSG_OK" in blob and "ENTRY_LUCI_OK" in blob,
)
check("T-UI-AUTH-REQUIRED", "NOAUTH:403" in blob and "AFTER:403" in blob)
check("T-UI-AUTH-BADPASS", "BADPASS:403" in blob)
check("T-UI-AUTH-LOGIN", "OKPASS:302" in blob and "SESS_COOKIE_OK" in blob)
check(
    "T-UI-LOGIN-BAR",
    "LOGIN_BAR_OK" in blob
    and "LOGIN_PLACE_OK" in blob
    and "LOGIN_LABEL_OK" in blob
    and "LOGIN_HREF_OK" in blob
    and "LOGIN_SIZE_OK" in blob
    and "LOGIN_BOLD_OK" in blob
    and "LOGIN_CENTER_OK" in blob
    and "LOGIN_TOPBAR_GONE" in blob,
)
check(
    "T-UI-NODE-DASH-MENU",
    "MENU_TITLE_OK" in blob
    and "MENU_EXIT_OK" in blob
    and "MENU_CTRL_OK" in blob
    and "NO_LUA_HTM_OK" in blob
    and "CSS_INLINE_OK" in blob
    and "ND:302" in blob
    and "ND_REDIR_OK" in blob
    and "POSTLOGOUT:403" in blob,
)
check("T-UI-DASH-HTTP", ("SETUP_DONE" in blob and "DASH:200" in blob)
      or ("SETUP_IUE" in blob and "DASH:302" in blob))

# Stronger: bad password must not be 200
bad = re.findall(r"BADPASS:(\d+)", blob)
if bad:
    check("T-UI-AUTH-BADPASS-CODE", bad[-1] != "200", f"got {bad[-1]}")

ser.close()
if fails:
    print("FAILED:", ", ".join(fails))
    sys.exit(1)
print("All device UI checks passed")
PY
