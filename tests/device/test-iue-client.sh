#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Client-perspective IUE test suite — drives the appliance from the Ubuntu LAN
# laptop's point of view (name resolution, HTTP entry, downloads, the real
# cert install, trust verification, Quick Start, Guided Setup) via:
#   - serial console to the appliance (SERIAL=/dev/ttyUSB0)
#   - ssh from the appliance to the laptop (PC_USER/PC_PASS/PC_IP)
#   - the laptop's own resolver/wget/store for all trust assertions
#
# The laptop is stock Ubuntu: wget exists, curl does NOT — all client HTTP
# checks use wget. sudo on the laptop is primed with PC_PASS inside the same
# ssh session as the privileged commands (sudo timestamps are per-session).
#
# Appliance must be in IUE state (setup-complete absent). Factory resets happen
# between flow tests (chain data on M.2 is never touched — N3/NF9).
#
# Usage: SERIAL=/dev/ttyUSB0 PC_IP=… PC_USER=… PC_PASS=… START_AT=C4 tests/device/test-iue-client.sh
# X6 (review 2026-10-11): no lab credentials or personal hosts in the repo —
# the LAN PC's address, user and password must be supplied by the operator.
set -euo pipefail
SERIAL="${SERIAL:?set SERIAL=/dev/ttyUSB0 (drives a real unit)}"
PC_USER="${PC_USER:?set PC_USER= (LAN PC account used over ssh)}"
PC_PASS="${PC_PASS:?set PC_PASS= (LAN PC password; never committed)}"
PC_IP="${PC_IP:?set PC_IP= (LAN PC address)}"
QUICK_PW="${QUICK_PW:-clienttest99}"
QUICK_WIFI_KEY="${QUICK_WIFI_KEY:-clientwifi99}"
GUIDED_PW="${GUIDED_PW:-clienttest88}"
GUIDED_SSID="${GUIDED_SSID:-ClientGuided}"
GUIDED_WIFI_KEY="${GUIDED_WIFI_KEY:-clientwifi88}"
START_AT="${START_AT:-P0}"

python3 - "$SERIAL" "$PC_USER" "$PC_PASS" "$PC_IP" \
  "$QUICK_PW" "$QUICK_WIFI_KEY" "$GUIDED_PW" "$GUIDED_SSID" "$GUIDED_WIFI_KEY" \
  "$START_AT" <<'PY'
import atexit, json, re, subprocess, sys, time, serial, termios

SERIAL, PC_USER, PC_PASS, PC_IP = sys.argv[1:5]
QUICK_PW, QUICK_WIFI_KEY, GUIDED_PW, GUIDED_SSID, GUIDED_WIFI_KEY = sys.argv[5:10]
START_AT = sys.argv[10]
SECTIONS = ["P0", "C1", "C2", "C3", "C4", "C5", "C6", "C7"]
if START_AT not in SECTIONS:
    print(f"unknown START_AT={START_AT} (want {SECTIONS})", flush=True)
    sys.exit(2)

def want(section):
    return SECTIONS.index(section) >= SECTIONS.index(START_AT)
FAILS = []
RESULTS = []

def ok(tc, name, cond, detail=""):
    line = ("PASS" if cond else "FAIL") + f" [{tc}] {name}" + (f" — {detail}" if detail and not cond else "")
    print(line, flush=True)
    RESULTS.append((tc, name, bool(cond)))
    if not cond:
        FAILS.append(f"{tc} {name}")

def info(msg):
    print(f"  .. {msg}", flush=True)

def count_ge1(out):
    """grep -c output of >=1 somewhere in the text."""
    return bool(re.search(r'(?m)^\s*([1-9]\d*)\s*$', out))

def rc_of(out):
    m = re.search(r'RC=(\d+)', out)
    return int(m.group(1)) if m else -1

# ---------------- serial driver (appliance console) -------------------------
class SerialNoModem(serial.Serial):
    def _update_dtr_state(self): return
    def _update_rts_state(self): return

ser = SerialNoModem()
ser.port, ser.baudrate, ser.timeout = SERIAL, 115200, 0.3
ser.write_timeout = 60
ser.xonxoff = ser.rtscts = ser.dsrdtr = False
ser.open()
# HUPCL: kernel pl2303 drops DTR on last close. Clone 067b:2303 chips treat that
# control transfer as a USB unplug (see docs/USB_SERIAL_TEST_DISCONNECT.md).
try:
    attrs = termios.tcgetattr(ser.fd)
    attrs[2] &= ~termios.HUPCL
    termios.tcsetattr(ser.fd, termios.TCSANOW, attrs)
except Exception:
    pass
try:
    subprocess.run(["stty", "-F", SERIAL, "-hupcl", "clocal"],
                   check=False, capture_output=True)
except Exception:
    pass
time.sleep(0.2)
try: ser.reset_input_buffer()
except Exception: pass

def host_pl2303():
    try:
        out = subprocess.check_output(["lsusb"], text=True)
    except Exception:
        return ""
    for ln in out.splitlines():
        if "067b" in ln or "PL2303" in ln:
            return ln.strip()
    return ""

USB_AT_OPEN = host_pl2303()

def _close_serial_safe():
    try:
        attrs = termios.tcgetattr(ser.fd)
        attrs[2] &= ~termios.HUPCL
        termios.tcsetattr(ser.fd, termios.TCSANOW, attrs)
    except Exception:
        pass
    try:
        ser.close()
    except Exception:
        pass

atexit.register(_close_serial_safe)

def at_prompt(data):
    """True when the serial buffer ends at the ash prompt.
    rstrip() removes the trailing space in 'root@node-router:~# ', so do not
    require that space after stripping."""
    if isinstance(data, bytes):
        data = data.decode("utf-8", "replace")
    return bool(re.search(r"root@node-router:~#\s*$", data.replace("\r", "")))

def wait_prompt(t=30):
    buf = b""; end = time.time() + t
    while time.time() < end:
        try:
            ch = ser.read(8192)
        except serial.SerialException:
            time.sleep(0.2)
            continue
        if ch:
            buf += ch
            if at_prompt(buf):
                return buf.decode("utf-8", "replace"), True
        else:
            time.sleep(0.03)
    return buf.decode("utf-8", "replace"), False

# X2 (review 2026-10-11): the serial console ECHOES every command, so a marker
# like `echo FOO_OK` (or a `;echo TOKEN` terminator) always appeared in the
# output even when the command failed. Split each echoed word with '' — the
# shell prints FOO_OK, the echoed command line shows FO''O_OK.
import re as _x2re
def quote_markers(s):
    return _x2re.sub(r"\becho (\w)(\w+)", r"echo \1''\2", s)

def sh(c, t=30):
    ser.write((quote_markers(c) + "\n").encode()); ser.flush()
    out, _ = wait_prompt(t)
    return out

def wait_shell(t=420):
    """Wait for ash. Newlines only — never Ctrl-C (interrupts U-Boot / factory-reset)."""
    acc = ""
    end = time.time() + t
    while time.time() < end:
        chunk = rd(1)
        if chunk:
            acc += chunk
        if at_prompt(acc):
            out = sh("id", 12)
            if "uid=0" in out:
                return True
            acc = ""
        else:
            ser.write(b"\n")
            ser.flush()
    return False

def wait_http(t=240):
    end = time.time() + t
    while time.time() < end:
        out = sh("curl -sS -m 12 http://127.0.0.1/api/setup?action=status", 20)
        if '"ok":true' in out:
            return True
        time.sleep(4)
    return False

def setup_markers_iue():
    out = sh("test -f /etc/knots/setup-complete && echo COMPLETE || echo IUE", 20)
    return "IUE" in out

# ---------------- Ubuntu laptop driver (ssh from the router) ----------------
def rd(t):
    buf = b""; end = time.time() + t
    while time.time() < end:
        try:
            ch = ser.read(8192)
        except serial.SerialException:
            time.sleep(0.2)
            continue
        if ch: buf += ch
        else: time.sleep(0.03)
    return buf.decode("utf-8", "replace")

def rd_until(tok, t=60):
    buf = b""; end = time.time() + t
    while time.time() < end:
        try:
            ch = ser.read(8192)
        except serial.SerialException:
            time.sleep(0.2)
            continue
        if ch:
            buf += ch
            if tok.encode() in buf:
                return buf.decode("utf-8", "replace"), True
        else:
            time.sleep(0.03)
    return buf.decode("utf-8", "replace"), False

def install_pc_helper():
    """Short router wrapper so laptop commands never wrap on the 80-col serial line."""
    ser.write(
        b"cat > /tmp/pcssh << 'EOF'\n"
        b"#!/bin/sh\n"
        + f"exec ssh -y -o StrictHostKeyChecking=no {PC_USER}@{PC_IP} bash -s\n".encode()
        + b"EOF\n"
    )
    ser.flush()
    wait_prompt(15)
    sh("chmod +x /tmp/pcssh")

def pc(cmdline, t=120, answers=1):
    """Run a command on the laptop via the router's ssh client.
    Command is staged in /tmp/pc-cmd.sh so the ssh argv stays short (serial wrap).
    Returns when ssh exits back to the router prompt."""
    # /tmp is tmpfs — factory-reset reboot deletes /tmp/pcssh.
    chk = sh("test -x /tmp/pcssh && echo PCSSH_OK || echo PCSSH_MISSING", 12)
    if "PCSSH_OK" not in chk:
        install_pc_helper()
    ser.write(b"cat > /tmp/pc-cmd.sh << 'PCEOF'\n")
    ser.flush()
    time.sleep(0.15)
    ser.write((cmdline + "\nPCEOF\n").encode())
    ser.flush()
    wait_prompt(15)
    ser.write(b"/tmp/pcssh < /tmp/pc-cmd.sh\n")
    ser.flush()
    out = ""
    pwd_sent = False
    hard = time.time() + t + 50
    deadline = time.time() + 45
    while time.time() < deadline and time.time() < hard:
        chunk = rd(1)
        if chunk:
            out += chunk
        if (not pwd_sent) and re.search(r"(?i)password:", out):
            ser.write((PC_PASS + "\n").encode())
            ser.flush()
            pwd_sent = True
            deadline = time.time() + t
        if at_prompt(out) and "/tmp/pcssh" in out:
            return out
    wait_prompt(8)
    return out

def wget_rc(url):
    return pc(f'wget -T 25 -q -O /dev/null "{url}" 2>/dev/null; echo RC=$?')

def wget_rc_wait(url, t=90):
    """Wait for LAN/HTTPS to come back after wifi reload / complete (not a sleep)."""
    last = ""
    end = time.time() + t
    while time.time() < end:
        last = wget_rc(url)
        if rc_of(last) == 0:
            return last
        time.sleep(3)
    return last

# ---------------- router-side helpers ----------------------------------------
def _parse_api_json(out):
    m = re.search(r"(\{.*\})", out, re.S)
    if not m:
        return None
    try:
        return json.loads(m.group(1))
    except Exception:
        return None

def rsh(cmdline, t=40):
    """Run a long router command via a staged script (avoids 80-col serial wrap)."""
    ser.write(b"cat > /tmp/rsh.sh << 'REOF'\n")
    ser.flush()
    time.sleep(0.12)
    ser.write((cmdline + "\nREOF\n").encode())
    ser.flush()
    wait_prompt(15)
    return sh("sh /tmp/rsh.sh", t)

def api(action, extra="", method="GET", tries=3):
    # Loopback :80 — nginx only proxies JSON on HTTP while setup is incomplete.
    http = f"http://127.0.0.1/api/setup?action={action}{extra}"
    https = f"https://127.0.0.1/api/setup?action={action}{extra}"
    out = ""
    for _ in range(tries):
        if method == "POST":
            out = rsh(f"curl -sS -m 55 -X POST '{http}'", 65)
        else:
            out = rsh(f"curl -sS -m 20 '{http}'", 35)
        j = _parse_api_json(out)
        if j is not None:
            return j
        if method == "GET":
            out = rsh(f"curl -sk -m 20 '{https}'", 35)
            j = _parse_api_json(out)
            if j is not None:
                return j
        time.sleep(3)
    return {"ok": False, "error": "no_json", "raw": out[-200:]}

def setup_is_complete():
    return not setup_markers_iue()

def node_impl():
    # Marker prefix — do not grep the word knots out of /etc/knots/ paths.
    out = sh("echo IMPL=$(cat /mnt/bitcoin/.node-impl 2>/dev/null || echo core)", 15)
    m = re.search(r"IMPL=(knots|core)", out)
    return m.group(1) if m else "core"

def https_setup_code(action="status"):
    # Marker prefix — do not match 127 from 127.0.0.1 in the echoed command.
    out = rsh(
        f"curl -sk -o /dev/null -w 'HC:%{{http_code}}' "
        f"https://127.0.0.1/api/setup?action={action}",
        25,
    )
    m = re.search(r"HC:(\d{3})", out)
    return m.group(1) if m else ""

def factory_reset():
    info("factory reset (restores IUE state; M.2 untouched)")
    usb0 = host_pl2303()
    # Read-only until reboot — do not type into the live factory-reset process.
    ser.write(b"/usr/sbin/factory-reset --confirm RESET\n")
    ser.flush()
    acc = ""
    boot_deadline = time.time() + 240
    while time.time() < boot_deadline:
        chunk = rd(2)
        if chunk:
            acc += chunk
        if re.search(
            r"(?i)(Linux version|U-Boot|BusyBox v|node-router login|BPI-R4 Bitcoin)",
            acc[-4000:],
        ):
            break
    if not wait_shell(420):
        return False
    usb1 = host_pl2303()
    if usb0 and usb1 and usb0 != usb1:
        info(f"USB serial re-enumerated during reset: {usb0} -> {usb1}")
        return False
    if not usb1:
        info("USB serial adapter missing after reset")
        return False
    if not wait_http(t=180):
        info("setup HTTP API not up after reset — checking markers")
    end = time.time() + 180
    while time.time() < end:
        if not setup_markers_iue():
            time.sleep(5)
            continue
        rsh("curl -sm12 -o /dev/null http://127.0.0.1/api/setup?action=factory_reset_clear || true", 20)
        st = api("status", tries=2)
        if st.get("complete") is False:
            install_pc_helper()
            return True
        install_pc_helper()
        return True
    return False

# =============================== P0: preconditions ===========================
print("=== P0 preconditions ===", flush=True)
wait_shell(60)
install_pc_helper()
if want("P0"):
    st = api("status")
    if not setup_markers_iue() or st.get("complete") is True or st.get("error") == "no_json":
        info("appliance not in IUE state — factory reset first (self-priming)")
        ok("P0-0", "priming factory reset", factory_reset())
        st = api("status")
    ok("P0-1", "appliance in IUE state (setup incomplete)", st.get("complete") is False, str(st)[:80])
    out = sh("/etc/init.d/avahi-daemon restart >/dev/null 2>&1; sleep 4; pgrep -af avahi-daemon | grep -v grep | head -1")
    ok("P0-2", "avahi-daemon running", "avahi-daemon" in out)
    out = sh("logread -e avahi | tail -6")
    ok("P0-3", "avahi publishes rnode.local, no collisions",
       "Host name is rnode.local" in out and "collision" not in out, out.strip()[-100:])
    stw = api("wan_status")
    ok("P0-4", "WAN up with IPv4", stw.get("up") is True and bool(stw.get("ipv4")), str(stw)[:60])
    out = pc("hostname && id", answers=2)
    ok("P0-5", f"laptop reachable via ssh ({PC_USER}@{PC_IP})", "uid=" in out, out.strip()[-60:])
else:
    info(f"START_AT={START_AT} — skip P0 assertions (shell already up)")
    out = pc("hostname && id", answers=2)
    if "uid=" not in out:
        ok("P0-5", f"laptop reachable via ssh ({PC_USER}@{PC_IP})", False, out.strip()[-60:])

# =============================== C1: name resolution =========================
if want("C1"):
    print("=== C1 name resolution from laptop ===", flush=True)
    out = pc("getent hosts rnode.local; echo RC=$?")
    ok("C1-1", "getent rnode.local resolves (nsswitch as a browser does)",
       "192.168.1.254" in out and rc_of(out) == 0, out.strip()[-60:])
    out = pc("nslookup rnode.local 192.168.1.254 2>&1 | tail -4")
    ok("C1-2", "nslookup via router DNS", "192.168.1.254" in out, out.strip()[-60:])
    out = pc("ping -c1 -W3 rnode.local 2>&1 | tail -2")
    ok("C1-3", "ping rnode.local replies", "0% packet loss" in out or "1 received" in out, out.strip()[-60:])

# =============================== C2: HTTP entry ==============================
if want("C2"):
    print("=== C2 HTTP entry (no TLS, no warning possible) ===", flush=True)
    out = pc('wget -S --max-redirect=0 -O /dev/null "http://rnode.local/" 2>&1 | grep -E "HTTP/1.1|Location:"')
    ok("C2-1", "GET / → 302 to /setup.html on HTTP (not HTTPS)",
       "302" in out and "setup.html" in out and "https" not in out.lower(), out.strip()[-120:])
    out = wget_rc("http://rnode.local/setup.html")
    ok("C2-2", "setup.html 200 over HTTP", rc_of(out) == 0, out.strip()[-60:])
    out = pc("wget -qO- http://rnode.local/setup.html | grep -c \"Welcome to RNode\"")
    ok("C2-3", "Welcome page copy present", count_ge1(out), out.strip()[-60:])
    out = pc("wget -qO- http://rnode.local/setup.html | grep -c \"tlsLinuxOneLiner\"")
    ok("C2-4", "Linux terminal box markup present", count_ge1(out), out.strip()[-60:])
    out = pc("wget -qO- http://rnode.local/setup.js | grep -c \"tlsLinuxQuick\"")
    ok("C2-5", "setup.js shows Linux box for Linux UA", count_ge1(out), out.strip()[-60:])
    out = pc("wget -qO- http://rnode.local/setup.js | grep -o \"wget -qO-\" | head -1")
    ok("C2-6", "one-liner is a wget|sh command", "wget -qO-" in out)
    out = pc("wget -qO- \"http://rnode.local/api/setup?action=status\"")
    ok("C2-7", "setup API answers on HTTP", '"ok":true' in out and '"complete":false' in out, out.strip()[-100:])
    ok("C2-8", "node default is Core", '"node_impl":"core"' in out)

# =============================== C3: trust downloads =========================
if want("C3"):
    print("=== C3 trust downloads from laptop ===", flush=True)
    for path, name in [("/knots-ca.crt", "1 CA cert"), ("/tls/install-linux.sh", "2 Linux installer"),
                       ("/tls/install-windows.bat", "3 Windows bat"), ("/tls/ios-profile.mobileconfig", "4 iOS profile")]:
        out = pc(f'wget -S -O /dev/null "http://rnode.local{path}" 2>&1 | grep -E "HTTP/1.1|Length:" | head -4')
        m = re.search(r'Length: (\d+)', out)
        ok("C3-" + name, f"{path} downloads with content",
           "200 OK" in out and m and int(m.group(1)) > 100, out.strip()[-80:])
    out = pc("wget -qO- http://rnode.local/tls/install-linux.sh | grep -c \"certutil\"")
    ok("C3-5", "installer handles Firefox store (NSS)", count_ge1(out))

# =============================== C4: real install on laptop ==================
if want("C4"):
    print("=== C4 cert install on laptop (the real one-liner) ===", flush=True)
    info("C4 cleanup: remove prior CA from system store")
    pc(f"echo {PC_PASS} | sudo -S rm -f /usr/local/share/ca-certificates/knots-ca.crt", t=40)
    pc(f"echo {PC_PASS} | sudo -S update-ca-certificates >/dev/null 2>&1; echo CLEANED", t=120)
    info("C4 cleanup: Firefox NSS nickname")
    pc("for p in $HOME/.mozilla/firefox/*.default* $HOME/snap/firefox/common/.mozilla/firefox/*.default*; do "
       "[ -d \"$p\" ] || continue; command -v certutil >/dev/null && "
       "certutil -d sql:$p -D -n \"Bitcoin Node CA\" >/dev/null 2>&1; done; echo FF-CLEANED", t=60)
    out = wget_rc("https://rnode.local/api/setup?action=status")
    ok("C4-1", "before install: HTTPS is NOT trusted by the laptop", rc_of(out) != 0, out.strip()[-60:])

    # Short ssh lines — long one-liners wrap on serial and break Dropbear ssh.
    pc("wget -q -O /tmp/knots-ca.crt http://rnode.local/knots-ca.crt", t=60)
    pc("wget -q -O /tmp/knots-install.sh http://rnode.local/tls/install-linux.sh", t=60)
    out = pc(
        f"echo {PC_PASS} | sudo -S env HOME=/home/{PC_USER} sh /tmp/knots-install.sh /tmp/knots-ca.crt 2>&1 | tail -30",
        t=300,
    )
    info("installer tail: " + out.strip()[-350:].replace("\n", " | "))
    ok("C4-2", "installer ran and reached the system store",
       "Done for the system certificate store" in out, out.strip()[-120:])

    out = wget_rc("https://rnode.local/api/setup?action=status")
    ok("C4-3", "after install: HTTPS probe target trusted (system store)",
       rc_of(out) == 0, out.strip()[-60:])
    out = pc("wget -qO- \"https://rnode.local/api/setup?action=status\" | grep -c \"ok.*true\"")
    ok("C4-4", "probe returns JSON ok (page's cors probe equivalent)", count_ge1(out), out.strip()[-60:])
    out = pc('wget -T 25 -S -O /dev/null "https://rnode.local:8443/cgi-bin/luci/" 2>&1 | grep "HTTP/" | tail -1')
    ok("C4-5", "LuCI :8443 also trusted (same CA)",
       bool(re.search(r"HTTP/1\.1 (200|302|403)", out)), out.strip()[-80:])

    has_certutil = "yes" in pc("command -v certutil >/dev/null && echo yes || echo no")
    if has_certutil:
        out = pc("for p in $HOME/.mozilla/firefox/*.default* $HOME/snap/firefox/common/.mozilla/firefox/*.default*; do "
                 "[ -d \"$p\" ] || continue; certutil -d sql:$p -L 2>/dev/null | grep -m1 \"Bitcoin Node CA\"; done | head -2")
        ok("C4-6", "CA present in Firefox store (NSS)", "Bitcoin Node CA" in out, out.strip()[-80:])
    else:
        info("certutil absent on laptop — Firefox manual import path (documented) applies")
        ok("C4-6", "Firefox store (NSS) — certutil unavailable, manual path documented", True)

# =============================== C5: Quick Start =============================
if want("C5"):
    print("=== C5 Quick Start path (as the browser calls the API) ===", flush=True)
    d = api("quickstart", "&lang=en&country=AU&zonename=Australia/Melbourne"
            f"&password={QUICK_PW}&password2={QUICK_PW}&wifipsk={QUICK_WIFI_KEY}", method="POST")
    ok("C5-1", "quickstart applies defaults + completes", d.get("ok") is True, str(d)[:120])
    # After complete, nginx seals HTTPS /api/setup with 404 (T-IUE-E2E-17). Use markers.
    ok("C5-2", "setup complete after quickstart", setup_is_complete())
    ok("C5-3", "node impl is Core (default)", node_impl() == "core", node_impl())
    out = sh("uci -q get wireless.default_radio0.ssid 2>/dev/null || uci -q show wireless | grep -m1 ssid")
    ok("C5-4", "Wi-Fi SSID is rnode", "rnode" in out, out.strip()[-60:])
    out = wget_rc_wait("https://rnode.local/")
    ok("C5-5", "dashboard reachable on HTTPS after complete (no wizard gate)",
       rc_of(out) == 0, out.strip()[-60:])
    code = https_setup_code("quickstart")
    ok("C5-6", "setup API sealed after complete (404)", code == "404", f"HTTP {code or '?'}")
    ok("C5-7", "factory reset restores IUE state", factory_reset())

# =============================== C6: Guided Setup ============================
if want("C6"):
    print("=== C6 Guided Setup path (as the browser calls the API) ===", flush=True)
    d = api("locale", "&lang=en&country=AU&zonename=Australia/Melbourne", method="POST")
    ok("C6-1", "locale applies", d.get("ok") is True, str(d)[:80])
    d = api("password", "&password=short&password2=short", method="POST")
    ok("C6-2", "short password rejected", d.get("ok") is False and d.get("error") == "too_short", str(d)[:80])
    d = api("password", f"&password={GUIDED_PW}&password2={GUIDED_PW}", method="POST")
    ok("C6-3", "password set", d.get("ok") is True, str(d)[:80])
    d = api("wan_dhcp", method="POST")
    ok("C6-4", "WAN DHCP applied", d.get("ok") is True, str(d)[:80])
    time.sleep(4)
    stw = api("wan_status")
    ok("C6-5", "WAN connected (no PPPoE popup needed)", stw.get("up") is True, str(stw)[:60])
    d = api("wifi", f"&ssid={GUIDED_SSID}&key={GUIDED_WIFI_KEY}&country=AU", method="POST")
    ok("C6-6", "custom Wi-Fi applies (Guided)", d.get("ok") is True, str(d)[:80])
    d = api("node", "&impl=knots", method="POST")
    ok("C6-7", "node switch to Knots (non-default choice works)", d.get("ok") is True, str(d)[:80])
    d = api("complete", method="POST")
    ok("C6-8", "complete after guided steps", d.get("ok") is True, str(d)[:80])
    ok("C6-9", "node impl is Knots after guided choice", node_impl() == "knots", node_impl())
    out = sh("uci -q get wireless.default_radio0.ssid 2>/dev/null || uci -q show wireless | grep -m1 ssid")
    ok("C6-10", "custom SSID applied", GUIDED_SSID in out, out.strip()[-60:])
    out = wget_rc_wait("https://rnode.local/")
    ok("C6-11", "dashboard reachable (trust persists across flows)",
       rc_of(out) == 0, out.strip()[-60:])
    # Setup API is sealed after complete — switch via node-impl (B15).
    # WALLET_ACK: Phase 2 IUE has no wallet UX; leftover lab wallet dirs on the
    # shared datadir must not block Core/Knots (same token setup_node_set uses).
    out = sh("/usr/libexec/knots/node-impl.sh set core SWITCH WALLET_ACK 2>&1 | tail -8", 180)
    ok("C6-12", "switch node back to Core",
       "switched_to core" in out or "already core" in out, out.strip()[-80:])
    ok("C6-13", "final factory reset — wizard left open for user testing", factory_reset())

# =============================== C7: post-reset sanity =======================
if want("C7"):
    print("=== C7 post-reset sanity from laptop ===", flush=True)
    out = pc("getent hosts rnode.local; echo RC=$?")
    ok("C7-1", "rnode.local still resolves after resets",
       "192.168.1.254" in out and rc_of(out) == 0, out.strip()[-60:])
    out = pc('wget -S --max-redirect=0 -O /dev/null "http://rnode.local/" 2>&1 | grep -E "HTTP/1.1|Location:"')
    ok("C7-2", "wizard entry back on HTTP", "302" in out and "setup.html" in out, out.strip()[-80:])
    out = wget_rc("https://rnode.local/api/setup?action=status")
    ok("C7-3", "installed CA still trusted (CA survives factory reset)",
       rc_of(out) == 0, out.strip()[-60:])

print("", flush=True)
usb_end = host_pl2303()
ok("USB-1", "PL2303 still enumerated (same adapter, no Event A)",
   bool(usb_end) and (not USB_AT_OPEN or usb_end == USB_AT_OPEN),
   f"{USB_AT_OPEN} -> {usb_end}")
fails_n = len(FAILS)
print(f"===== RESULT: {len(RESULTS) - fails_n}/{len(RESULTS)} PASS, {fails_n} FAIL =====", flush=True)
if FAILS:
    print("FAILED: " + ", ".join(FAILS), flush=True)
sys.exit(1 if FAILS else 0)
PY
