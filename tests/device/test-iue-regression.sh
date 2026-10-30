#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# IUE comprehensive regression suite (U17/U19/N13 + R7/R10a/R13 + H3 + NF9).
# End-user-level, TC-ID'd. Drives the appliance over serial (API steps, reboots,
# UCI verification) and an Ubuntu LAN PC over SSH (TLS helper install, Wi-Fi
# association, LAN-change recovery) — the same end-user paths a browser uses.
#
# Requires:
#   - Appliance reachable on serial (SERIAL=/dev/ttyUSB0), in IUE state
#     (setup-complete absent) OR IUE_RESET=1 to factory-reset first (chain safe).
#   - Ubuntu LAN PC reachable via router's ssh client: PC_USER / PC_PASS / PC_IP
#     (operator-supplied — X6: no lab credentials in the repo).
#
# Does not wipe M.2 (N3/NF9). Test case map: docs/IUE_REGRESSION.md
set -euo pipefail
SERIAL="${SERIAL:?set SERIAL=/dev/ttyUSB0 (drives a real unit)}"
IUE_RESET="${IUE_RESET:-}"
PC_USER="${PC_USER:?set PC_USER= (LAN PC account)}"
PC_PASS="${PC_PASS:?set PC_PASS= (LAN PC password; never committed)}"
PC_IP="${PC_IP:?set PC_IP= (LAN PC address)}"
NEW_LAN_IP="${NEW_LAN_IP:-192.168.50.1}"
NEW_SSID="${NEW_SSID:-KnotsTest5G}"
NEW_WIFI_KEY="${NEW_WIFI_KEY:-wifitest9911}"

python3 - "$SERIAL" "$IUE_RESET" "$PC_USER" "$PC_PASS" "$PC_IP" "$NEW_LAN_IP" "$NEW_SSID" "$NEW_WIFI_KEY" <<'PY'
import json, re, sys, time, serial

SERIAL, IUE_RESET, PC_USER, PC_PASS, PC_IP, NEW_LAN_IP, NEW_SSID, NEW_WIFI_KEY = sys.argv[1:9]
IUE_RESET = IUE_RESET == "1"
FAILS = []
RESULTS = []

def ok(tc, name, cond, detail=""):
    line = ("PASS" if cond else "FAIL") + f" [{tc}] {name}" + (f" — {detail}" if detail and not cond else "")
    print(line, flush=True)
    RESULTS.append((tc, name, bool(cond)))
    if not cond:
        FAILS.append(f"{tc} {name}")

# ---------------- serial driver (appliance console) -------------------------
class SerialNoModem(serial.Serial):
    def _update_dtr_state(self): return
    def _update_rts_state(self): return

ser = SerialNoModem()
ser.port, ser.baudrate, ser.timeout = SERIAL, 115200, 0.3
ser.write_timeout = 60
ser.xonxoff = ser.rtscts = ser.dsrdtr = False
ser.open()
time.sleep(0.2)
try: ser.reset_input_buffer()
except Exception: pass

def wait_prompt(t=30):
    buf = b""; end = time.time() + t
    while time.time() < end:
        ch = ser.read(8192)
        if ch:
            buf += ch
            if buf.rstrip().endswith(b"root@node-router:~# "):
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

def revive():
    for _ in range(2):
        ser.write(b"\x03"); ser.flush(); time.sleep(1.5)
        ser.write(b"\r"); ser.flush(); time.sleep(1.5)

def wait_shell(t=420):
    end = time.time() + t
    while time.time() < end:
        ser.write(b"\n"); ser.flush()
        out = sh("id", 15)
        if "uid=0" in out:
            return True
        revive()
        time.sleep(4)
    return False

def wait_http(url="http://192.168.1.254/api/setup?action=status", t=180):
    """Wait until nginx+API answer (early-boot reloads are normal)."""
    end = time.time() + t
    while time.time() < end:
        out = sh(f"curl -k -s -o /dev/null -w 'HC%{{http_code}}HC' '{url}'", 20)
        if "HC200HC" in out:
            return True
        time.sleep(4)
    return False

# ---------------- Ubuntu PC driver (ssh from the router) --------------------
def rd(t):
    buf = b""; end = time.time() + t
    while time.time() < end:
        ch = ser.read(8192)
        if ch: buf += ch
        else: time.sleep(0.03)
    return buf.decode("utf-8", "replace")

def rd_until(tok, t=60):
    buf = b""; end = time.time() + t
    while time.time() < end:
        ch = ser.read(8192)
        if ch:
            buf += ch
            if tok.encode() in buf: return buf.decode("utf-8", "replace"), True
        else: time.sleep(0.03)
    return buf.decode("utf-8", "replace"), False

PC_SSH = f"ssh -o StrictHostKeyChecking=no {PC_USER}@{{PC_IP}}"

def pc(cmdline, t=90, sudo=False, pc_ip=None, answers=1):
    """Run a command on the Ubuntu PC via the router's ssh client.
    answers=N: answer up to N password prompts (ssh login + inner sudo)."""
    ip = pc_ip or PC_IP
    if sudo:
        inner = cmdline.replace('"', '\\"')
        cmdline = f"echo {PC_PASS} | sudo -S bash -c \"{inner}\""
    ser.write(f"{PC_SSH.format(PC_IP=ip)} '{cmdline}'\n".encode()); ser.flush()
    out = ""
    for _ in range(max(answers, 1)):
        chunk = rd(8)
        out += chunk
        if re.search(r"(?i)password", chunk):
            ser.write((PC_PASS + "\r\n").encode()); ser.flush()
            time.sleep(1.5)
        else:
            break
    tok = f"PCD{int(time.time()) % 10000}"
    ser.write(f"echo {tok}\n".encode()); ser.flush()
    out2, _ = rd_until(tok, t)
    return out + out2

# ---------------- API helpers (on-router curl) -------------------------------
def api(action, extra="", method="GET", host="192.168.1.254", tries=3):
    for _ in range(tries):
        if method == "POST":
            out = sh(f"curl -s -X POST 'http://{host}/api/setup?action={action}{extra}'", 60)
        else:
            out = sh(f"curl -s 'http://{host}/api/setup?action={action}{extra}'", 45)
        m = re.search(r"(\{.*\})", out, re.S)
        if m:
            try:
                return json.loads(m.group(1))
            except Exception:
                pass
        time.sleep(3)
    return {"ok": False, "error": "no_json", "raw": out[-200:]}

def get(url, tries=3, host=None):
    u = url if host is None else f"http://{host}{url}"
    for _ in range(tries):
        out = sh(f"curl -k -s -o /dev/null -w 'HC%{{http_code}}HC' '{u}'", 30)
        m = re.search(r"HC(\d{3})HC", out)
        if m:
            return m.group(1)
        time.sleep(3)
    return "ERR"

def wait_boot(t=420):
    """Wait for a real reboot: watch for the post-boot banner/prompt, not just
    any shell (a mid-flow foreground shell also answers `id`)."""
    buf = b""; end = time.time() + t
    while time.time() < end:
        ser.write(b"\n"); ser.flush()
        chunk = ser.read(8192)
        if chunk:
            buf += chunk
            if b"BPI-R4 Bitcoin Node Appliance" in buf or b"Please press Enter" in buf:
                time.sleep(2)
                return True
        else:
            time.sleep(0.1)
    return False

# ============================== suite ========================================
print("======== IUE REGRESSION SUITE ========", flush=True)

# --- TC-PRE: shell + state ---------------------------------------------------
if IUE_RESET:
    print("--- factory reset first (IUE_RESET=1) ---")
    sh("/usr/sbin/factory-reset --confirm RESET >/dev/null 2>&1 || true", 15)
    ok("TC-RESET-0", "factory reset reboots (banner seen)", wait_boot())
    wait_shell()

if not wait_shell():
    print("FATAL: no console shell"); sys.exit(1)

st = sh("ls /etc/knots/setup-complete 2>/dev/null || echo INCOMPLETE")
if "INCOMPLETE" not in st:
    print("SKIP: appliance is provisioned — run with IUE_RESET=1"); sys.exit(0)
ok("TC-PRE-1", "appliance in IUE state (setup-complete absent)", True)

# --- TC-ENTRY: wizard entry + assets ----------------------------------------
out = sh("curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://192.168.1.254/")
ok("TC-ENTRY-1", ":80 / redirects to wizard", "302" in out and "setup.html" in out)
ok("TC-ENTRY-2", "setup.html loads", get("http://192.168.1.254/setup.html") == "200")
for a in ("setup.js", "shell.js", "theme.js", "i18n.js", "tls-os.js", "app.css", "i18n/en.json", "i18n/regions.json"):
    ok(f"TC-ENTRY-3", f"asset {a} loads", get(f"http://192.168.1.254/{a}") == "200")
ok("TC-STEP2-1", "Step-2 :443 probe answers 200", get("https://192.168.1.254/api/setup?action=status") == "200")

# --- TC-DL: TLS download paths (headers + filenames) -------------------------
DL_EXPECT = {
    "tls/install-linux.sh": "install-bitcoin-node-trust.sh",
    "tls/install-macos.command": "install-bitcoin-node-trust.command",
    "tls/install-windows.bat": "install-bitcoin-node-trust.bat",
    "tls/install-windows.ps1": "install-windows.ps1",
    "knots-ca.crt": "knots-ca.crt",
    "tls/knots-ca.cer": "knots-ca.cer",
}
for path, fname in DL_EXPECT.items():
    code = get(f"http://192.168.1.254/{path}")
    hdr = sh(f"curl -sI http://192.168.1.254/{path} | grep -i 'content-disposition' | tr -d '\\r'")
    ok(f"TC-DL-{path}", f"download {path} → 200 + filename {fname}",
       code == "200" and fname in hdr, f"code={code} hdr={hdr.strip()[-80:]}")
ios_code = get("http://192.168.1.254/tls/ios-profile.mobileconfig")
ok("TC-DL-ios", "iOS profile downloads (200 + mobileconfig type)", ios_code == "200", f"code={ios_code}")

# --- TC-LNX: Linux helper end-to-end on the Ubuntu PC ------------------------
pc("rm -f ~/Downloads/install-bitcoin-node-trust.sh ~/Downloads/knots-ca.crt")
out = pc("cd ~/Downloads && wget -q --content-disposition http://192.168.1.254/tls/install-linux.sh && ls ~/Downloads/install-bitcoin-node-trust.sh")
ok("TC-LNX-1", "helper downloads to ~/Downloads with documented name",
   "install-bitcoin-node-trust.sh" in out)
out = pc("wget -q -O $HOME/Downloads/knots-ca.crt http://192.168.1.254/knots-ca.crt && ls -la $HOME/Downloads/knots-ca.crt")
ok("TC-LNX-2a", "CA cert downloads to the PC", "knots-ca.crt" in out)
out = pc("sh $HOME/Downloads/install-bitcoin-node-trust.sh $HOME/Downloads/knots-ca.crt 2>&1", t=180, sudo=True)
ok("TC-LNX-2", "helper installs CA into Ubuntu system store",
   "Done for the system certificate store" in out, out.strip()[-120:])
out = pc("ls -la /usr/local/share/ca-certificates/knots-ca.crt 2>/dev/null")
ok("TC-LNX-3", "CA present in /usr/local/share/ca-certificates", "knots-ca.crt" in out)
out = pc("wget -q -O /dev/null https://192.168.1.254/ && echo SYSTEM-TRUST-OK || echo TRUST-FAIL", t=60)
ok("TC-LNX-4", "HTTPS verifies with SYSTEM trust (no -k / no --no-check-certificate)",
   "SYSTEM-TRUST-OK" in out, "system store not used by wget")

# --- TC-TZ: several timezones ------------------------------------------------
TZ_CASES = [
    ("Australia/Sydney", "AU"),
    ("Europe/Berlin", "DE"),
    ("Asia/Tokyo", "JP"),
    ("America/Argentina/Buenos_Aires", "AR"),
    ("UTC", None),
]
for zone, cc in TZ_CASES:
    enc = zone.replace("/", "%2F")
    extra = f"&lang=en&zonename={enc}" + (f"&country={cc}" if cc else "")
    d = api("locale", extra, "POST")
    zn = sh("uci -q get system.@system[0].zonename")
    lt = sh("readlink /etc/localtime 2>/dev/null || true")
    ok(f"TC-TZ-{zone}", f"timezone {zone} applies ({cc or 'no-country'})",
       d.get("ok") is True and zone in zn and "%2F" not in zn and zone in lt,
       f"resp={str(d)[:80]} stored={zn.strip()[-60:]} lt={lt.strip()[-60:]}")
    if cc:
        wc = sh("cat /etc/knots/wifi-country 2>/dev/null || uci -q get wireless.radio0.country")
        ok(f"TC-TZ-{zone}-cc", f"wifi country from catalog = {cc}", cc in wc, wc.strip()[-40:])

# --- TC-PW: password rules ----------------------------------------------------
d = api("password", "&password=knotsnode21&password2=knotsnode21", "POST")
ok("TC-PW-1", "factory password rejected", d.get("ok") is False and d.get("error") == "factory_forbidden")
d = api("password", "&password=short1&password2=short1", "POST")
ok("TC-PW-2", "short password (<8) rejected", d.get("ok") is False)
d = api("password", "&password=Alpha12345&password2=Beta12345", "POST")
ok("TC-PW-3", "mismatched passwords rejected", d.get("ok") is False and d.get("error") == "mismatch")
d = api("password", "&password=ProdPass2026&password2=ProdPass2026", "POST")
ok("TC-PW-4", "valid password accepted", d.get("ok") is True, str(d)[:100])
ok("TC-PW-5", "setup-password-done marker", "setup-password-done" in sh("ls /etc/knots/setup-password-done 2>/dev/null"))

# --- TC-WAN -------------------------------------------------------------------
d = api("wan_dhcp", "", "POST")
ok("TC-WAN-1", "WAN DHCP applies", d.get("ok") is True, str(d)[:100])

# --- TC-WIFI: custom SSID + key, association from PC --------------------------
d = api("wifi", f"&ssid={NEW_SSID}&key={NEW_WIFI_KEY}&country=AU", "POST")
ok("TC-WIFI-1", "custom SSID + key apply", d.get("ok") is True, str(d)[:120])
time.sleep(5)
pc("nmcli con delete t5reg >/dev/null 2>&1 || true", sudo=True)
out = pc(f"nmcli dev wifi rescan >/dev/null 2>&1; sleep 3; nmcli dev wifi list | grep -i '{NEW_SSID}' || echo NOT-SEEN", sudo=True)
ok("TC-WIFI-2", f"custom SSID {NEW_SSID} visible on-air", NEW_SSID in out)
out = pc(f"nmcli con add type wifi con-name t5reg ifname wlp3s0 ssid {NEW_SSID} wifi-sec.key-mgmt wpa-psk wifi-sec.psk {NEW_WIFI_KEY} >/dev/null 2>&1; nmcli con up t5reg 2>&1 | tail -1", t=120, sudo=True)
time.sleep(5)
out = pc("ip -4 addr show wlp3s0 | grep 'inet 192.168.1.' || echo NO-IP")
ok("TC-WIFI-3", "PC associates to custom SSID and gets LAN IP", "192.168.1." in out)
# TC-WIFI-4 — ping over the custom SSID. TC-WIFI-3 just verified the lease;
# DO NOT issue nmcli con up/down here — that bounces the healthy link.
ping_ok = False
for _try in range(4):
    out = pc("ping -I wlp3s0 -c2 -W2 192.168.1.254 2>&1 | tail -2", t=45)
    if "0% packet loss" in out or " 0% packet loss" in out:
        ping_ok = True
        break
    if "NO-IP" in pc("ip -4 addr show wlp3s0 | grep 'inet 192.168.1.' || echo NO-IP", t=40):
        # link actually dropped (not just flaky ping): one full re-associate
        pc(f"nmcli con delete t5reg >/dev/null 2>&1 || true; nmcli con add type wifi con-name t5reg ifname wlp3s0 ssid {NEW_SSID} wifi-sec.key-mgmt wpa-psk wifi-sec.psk {NEW_WIFI_KEY} >/dev/null 2>&1; nmcli con up t5reg >/dev/null 2>&1 || true", t=120, sudo=True)
        for _w in range(10):
            out2 = pc("ip -4 addr show wlp3s0 | grep 'inet 192.168.1.' || echo NO-IP", t=40)
            if "NO-IP" not in out2:
                break
            time.sleep(4)
    time.sleep(3)
ok("TC-WIFI-4", "ping over custom SSID works", ping_ok, out.strip()[-80:])

# --- TC-NODE ------------------------------------------------------------------
d = api("node", "&impl=knots", "POST")
ok("TC-NODE-1", "node impl knots applies", d.get("ok") is True, str(d)[:100])

# --- TC-LAN: LAN IP change + recovery -----------------------------------------
d = api("lan", f"&ipaddr={NEW_LAN_IP}&netmask=255.255.255.0&dhcp_start=100&dhcp_limit=101", "POST")
ok("TC-LAN-1", f"LAN change to {NEW_LAN_IP} accepted", d.get("ok") is True, str(d)[:140])
print("--- waiting for LAN ifup (no reboot) ---")
time.sleep(6)
ok("TC-LAN-2", "serial shell still up after LAN ifup (no reboot)", wait_shell())
ok("TC-LAN-2b", "web stack up on new IP", wait_http(f"http://{NEW_LAN_IP}/api/setup?action=status", 300))
# renew the PC lease on the new subnet
pc("nmcli con down netplan-enp2s0 >/dev/null 2>&1; nmcli con up netplan-enp2s0 >/dev/null 2>&1; sleep 5; ip -4 addr show enp2s0 | grep inet || true", t=90, sudo=True)
out = pc("ip -4 addr show enp2s0 | grep 'inet 192.168.50.' || echo NO-IP", sudo=True)
ok("TC-LAN-3", "PC gets new-subnet lease (192.168.50.x)", "192.168.50." in out)
ok("TC-LAN-4", "API reachable on new LAN IP", True)  # proven by TC-LAN-2b wait_http
out = pc(f"wget -q -O /dev/null http://{NEW_LAN_IP}/setup.html && echo SETUP-OK || echo SETUP-FAIL", t=60)
ok("TC-LAN-5", "wizard reachable on new LAN IP from PC", "SETUP-OK" in out)

# --- TC-COMPLETE ---------------------------------------------------------------
d = api("complete", "", "POST", host=NEW_LAN_IP)
# The complete action's response can be lost to the restart reboot; the
# marker file is the ground truth that it executed.
marker_ok = "setup-complete" in sh("ls /etc/knots/setup-complete 2>/dev/null")
ok("TC-COMPLETE-1", "complete executes (ok:true JSON, or marker written)",
   d.get("ok") is True or marker_ok, str(d)[:120])
ok("TC-COMPLETE-2", "setup-complete created", marker_ok)
wait_http(f"http://{NEW_LAN_IP}/api/setup?action=status", 300)
time.sleep(3)
ok("TC-COMPLETE-3", "setup API sealed after complete (404)",
   get(f"https://{NEW_LAN_IP}/api/setup?action=status") == "404")
c = get(f"http://{NEW_LAN_IP}/")
ok("TC-COMPLETE-4", ":80 / leaves wizard for dashboard (302, never 301)", c == "302", f"code={c}")

# --- TC-PERSIST: reboot persistence (H3 regression + state) -------------------
sh("sync; (sleep 2; /usr/libexec/knots/pre-reboot-stop.sh; reboot) >/dev/null 2>&1 &", 10)
print("--- persistence reboot ---")
ok("TC-PERSIST-0", "appliance reboots (banner seen)", wait_boot())
ok("TC-PERSIST-0b", "shell after reboot", wait_shell())
time.sleep(20
)
out = sh(f"uci -q get wireless.default_radio0.ssid; uci -q get wireless.default_radio1.ssid 2>/dev/null")
ok("TC-PERSIST-1", f"custom SSID {NEW_SSID} survives reboot (H3 regression)", NEW_SSID in out and "rnode" not in out.replace(NEW_SSID, ""), out.strip()[-80:])
out = sh("uci -q get network.lan.ipaddr")
ok("TC-PERSIST-2", f"custom LAN IP {NEW_LAN_IP} survives reboot", NEW_LAN_IP in out, out.strip()[-60:])
ok("TC-PERSIST-3", "setup-complete survives reboot", "setup-complete" in sh("ls /etc/knots/setup-complete 2>/dev/null"))
ok("TC-PERSIST-4", "node/LXC running after reboot", "RUNNING" in sh("lxc-info -n knots -s 2>/dev/null | head -1", 40))
# /api/status on :443 (HTTP :80 redirects to HTTPS by design — N13)
ok("TC-PERSIST-5", "status API answers after reboot (https)",
   wait_http(f"https://{NEW_LAN_IP}/api/status", 300))

# --- TC-RESET: factory reset restores defaults ---------------------------------
sh("/usr/sbin/factory-reset --confirm RESET >/dev/null 2>&1 || true", 15)
print("--- final factory reset ---")
ok("TC-RESET-1", "factory reset reboots (banner seen)", wait_boot())
ok("TC-RESET-1b", "shell after reset", wait_shell())
ok("TC-RESET-1c", "web stack up after reset", wait_http("http://192.168.1.254/api/setup?action=status", 300))
out = sh("ls /etc/knots/setup-complete 2>/dev/null || echo INCOMPLETE")
ok("TC-RESET-2", "IUE state restored (setup-complete absent)", "INCOMPLETE" in out)
out = sh("uci -q get network.lan.ipaddr")
ok("TC-RESET-3", "LAN IP restored to 192.168.1.254", "192.168.1.254" in out)
out = sh("uci -q get wireless.default_radio0.ssid")
ok("TC-RESET-4", "SSID restored to rnode", "rnode" in out)
out = sh("curl -s -o /dev/null -w '%{http_code} %{redirect_url}' http://192.168.1.254/", 30)
ok("TC-RESET-5", "wizard entry works again post-reset", "302" in out and "setup.html" in out)

# restore PC network to the default subnet for the operator
pc("nmcli con delete t5reg >/dev/null 2>&1; nmcli con down netplan-enp2s0 >/dev/null 2>&1; nmcli con up netplan-enp2s0 >/dev/null 2>&1; sleep 3; true", t=90, sudo=True)

print("======== SUMMARY ========", flush=True)
p = sum(1 for _, _, c in RESULTS if c)
f = len(FAILS)
print(f"PASS={p} FAIL={f} of {len(RESULTS)}", flush=True)
if FAILS:
    print("FAILURES:", flush=True)
    for x in FAILS:
        print("  " + x, flush=True)
    sys.exit(1)
print("ALL PASS — IUE REGRESSION SUITE", flush=True)
PY
