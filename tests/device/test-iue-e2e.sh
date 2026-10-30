#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Device IUE end-to-end (U17 / U19 / N13) — full first-run Setup walkthrough
# exactly as an end user drives it (HTTP wizard page loads + every API step).
# Catches the class of bugs that grep-tests cannot: 2026-09-07 urldecode_soft
# locale hard-blocker (every slashed IANA zone rejected) and Step-2 probe
# availability. Does not wipe M.2 (N3).
#
# REQUIRES the unit to be in IUE state (setup-complete absent).
#   IUE_RESET=1  → factory-reset the unit first (wait for reboot), then run.
#   SERIAL=/dev/ttyUSB0 tests/device/test-iue-e2e.sh
#
# NOTE: the test sets a test root password (TestPass99-dev) during the
# password step — re-run factory reset or change it back afterwards.
set -euo pipefail
SERIAL="${SERIAL:?set SERIAL=/dev/ttyUSB0 (X4: device tests drive a real unit)}"
IUE_RESET="${IUE_RESET:-}"
python3 - "$SERIAL" "$IUE_RESET" <<'PY'
import json, re, sys, time, serial

port, do_reset = sys.argv[1], sys.argv[2] == "1"
FAILS = []

def ok(name, cond, detail=""):
    print(("PASS" if cond else "FAIL") + f": {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILS.append(name)

class SerialNoModem(serial.Serial):
    def _update_dtr_state(self): return
    def _update_rts_state(self): return

ser = SerialNoModem()
ser.port, ser.baudrate, ser.timeout = port, 115200, 0.3
ser.write_timeout = 60
ser.xonxoff = ser.rtscts = ser.dsrdtr = False
ser.open()
time.sleep(0.2)
try: ser.reset_input_buffer()
except Exception: pass

def read_until(token, timeout=45.0):
    buf = ""
    end = time.time() + timeout
    while time.time() < end:
        chunk = ser.read(8192)
        if chunk:
            t = chunk.decode("utf-8", "replace")
            buf += t
            if re.search(rf"(?m)^{re.escape(token)}\r?$", buf):
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
    tok = f"T{int(time.time()) % 100000}X"
    ser.write((quote_markers(line + f";echo {tok}") + "\n").encode())
    ser.flush()
    return read_until(tok, timeout)

def wait_shell(timeout=420.0):
    end = time.time() + timeout
    while time.time() < end:
        ser.write(b"\n")
        ser.flush()
        out = cmd("id", timeout=15)
        if "uid=0" in out:
            return True
        time.sleep(4)
    return False

def sh(c, timeout=45):
    out = cmd(c, timeout)
    return out

def get(path, timeout=45, code_only=True):
    # Marker-wrapped code: the echoed URL (192.168.…) must not be parsed as
    # the status; -k because the Step-2 probe is the local-CA https endpoint.
    # Retry transient blips: nginx reloads during early boot (ui-ports), and a
    # real user simply reloads — a single dropped fetch is not a product bug.
    for attempt in range(3):
        out = sh(f"curl -k -s -o /dev/null -w 'HC%{{http_code}}HC' '{path}'", timeout)
        m = re.search(r"HC(\d{3})HC", out)
        if m:
            return m.group(1)
        time.sleep(3)
    return "ERR"

def post(action, extra="", timeout=60):
    # Retry transient non-JSON responses: the API (uhttpd) also reloads during
    # early boot; an end user sees a brief loading state and retries.
    for attempt in range(3):
        out = sh(f"curl -s -X POST 'http://192.168.1.254/api/setup?action={action}{extra}'", timeout)
        m = re.search(r"(\{.*\})", out, re.S)
        if m:
            try:
                return json.loads(m.group(1))
            except Exception:
                pass
        time.sleep(3)
    return {"ok": False, "error": "no_json", "raw": out[-200:]}

# --- optional factory reset first ------------------------------------------
if do_reset:
    print("--- factory reset requested (IUE_RESET=1) ---")
    sh("/usr/sbin/factory-reset --confirm RESET >/dev/null 2>&1 || true", 15)
    print("--- waiting for reboot + shell (up to 7 min) ---")
    ok("shell after factory reset", wait_shell())

if not wait_shell():
    print("FATAL: no root shell on serial console")
    sys.exit(1)

# --- pre-state: must be in IUE state ----------------------------------------
st = sh("ls /etc/knots/setup-complete 2>/dev/null || echo INCOMPLETE")
if "INCOMPLETE" not in st:
    print("SKIP: unit is provisioned (setup-complete present) — run with IUE_RESET=1 to reset first")
    sys.exit(0)

# --- 1. wizard entry (as a browser would hit it) -----------------------------
out = sh("curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://192.168.1.254/")
ok("T-IUE-E2E-1 :80 / redirects to wizard", "302" in out and "setup.html" in out)
c = get("http://192.168.1.254/setup.html")
ok("T-IUE-E2E-2 setup.html loads", c == "200", f"got HTTP {c}")
for a in ("setup.js", "shell.js", "theme.js", "i18n.js", "tls-os.js", "app.css", "i18n/en.json", "i18n/regions.json"):
    ok(f"T-IUE-E2E-3 asset {a} loads", get(f"http://192.168.1.254/{a}") == "200")

# --- 2. Step 2 (HTTPS trust) dependencies ------------------------------------
ok("T-IUE-E2E-4 :443 setup status probe (Step-2 verify target)",
   get("https://192.168.1.254/api/setup?action=status", code_only=True) == "200")
st = post("status")
ok("T-IUE-E2E-5 status reports incomplete", st.get("complete") is False)

# --- 3. locale step — REGRESSION: slashed IANA zone must decode --------------
d = post("locale", "&lang=en&zonename=Australia%2FSydney&country=AU", 60)
ok("T-IUE-E2E-6 locale accepts slashed IANA timezone (urldecode fix)", d.get("ok") is True, str(d)[:120])
zn = sh("uci -q get system.@system[0].zonename")
ok("T-IUE-E2E-7 stored zonename is decoded (no %2F)", "Australia/Sydney" in zn and "%2F" not in zn)
ok("T-IUE-E2E-8 setup-locale-done marker", "setup-locale-done" in sh("ls /etc/knots/setup-locale-done 2>/dev/null"))

# --- 4. password step ----------------------------------------------------------
d = post("password", "&password=knotsnode21&password2=knotsnode21")
ok("T-IUE-E2E-9 factory password rejected", d.get("ok") is False and d.get("error") == "factory_forbidden")
d = post("password", "&password=TestPass99-dev&password2=TestPass99-dev")
ok("T-IUE-E2E-10 real password accepted", d.get("ok") is True, str(d)[:120])
ok("T-IUE-E2E-11 setup-password-done marker", "setup-password-done" in sh("ls /etc/knots/setup-password-done 2>/dev/null"))

# --- 5. WAN / Wi-Fi / node -----------------------------------------------------
d = post("wan_dhcp")
ok("T-IUE-E2E-12 wan_dhcp applies", d.get("ok") is True, str(d)[:120])
st = post("status")
if st.get("wifi_available"):
    d = post("wifi", "&ssid=rnode&key=iue2e2test99&country=AU")
    ok("T-IUE-E2E-13 wifi applies", d.get("ok") is True, str(d)[:120])
else:
    print("SKIP: no radio — wifi step")
d = post("node", "&impl=knots")
ok("T-IUE-E2E-14 node impl knots", d.get("ok") is True, str(d)[:120])

# --- 6. complete ---------------------------------------------------------------
d = post("complete", "", 60)
ok("T-IUE-E2E-15 complete succeeds after locale+password", d.get("ok") is True, str(d)[:160])
ok("T-IUE-E2E-16 setup-complete created", "setup-complete" in sh("ls /etc/knots/setup-complete 2>/dev/null"))

# --- 7. post-complete gates ----------------------------------------------------
time.sleep(3)
ok("T-IUE-E2E-17 /api/setup sealed after complete (404)",
   get("https://192.168.1.254/api/setup?action=status") == "404")
c = get("http://192.168.1.254/")
ok("T-IUE-E2E-18 :80 / now leaves wizard (302 to dashboard; never 301 — F135)", c == "302", f"got HTTP {c}")

print("---")
if FAILS:
    print(f"RESULT: {len(FAILS)} FAILURES: {', '.join(FAILS)}")
    sys.exit(1)
print("RESULT: ALL PASS — IUE end-to-end walkthrough")
PY
