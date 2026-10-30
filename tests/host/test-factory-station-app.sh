#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-STATION-APP — the factory station screen (factory/station) end to end
# against a SIMULATED router on a pty: U-Boot countdown + menu, partition
# table (7391), TFTP writes (preloader, FIP, production), reboot, console
# login, verify, provisioning over serial (label secret = HMAC(factory key,
# MAC), labels.csv), label mode + blue LED + WPS press → batch complete.
# Also: a wrong partition table stops the bay; the batch size is remembered.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
python3 -c 'import serial, PIL' 2>/dev/null || { echo "SKIP: pyserial/PIL missing"; exit 0; }
OV=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env"); KV=$(sed -n 's/^KNOTS_VER := //p' "$ROOT/build/version.env")
BN=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env"); VER="$OV.$KV.$BN"
[ -f "$ROOT/bin/targets/mediatek/filogic/bpi-r4-phase2-$VER-sdcard.img.gz" ] || { echo "SKIP: no build for $VER (make image)"; exit 0; }
W=$(mktemp -d); trap 'kill $(cat "$W/pids" 2>/dev/null) 2>/dev/null || true; rm -rf "$W"' EXIT
sh "$ROOT/factory/make-station-bundle.sh" "$W/b" >/dev/null || fail "bundle"
B="$W/b/rnode-factory"
for f in factory/station/rnode_station.py factory/station/web/index.html factory/station/start-station.sh \
	"images/$VER/tftp-bootloader.sha256"; do [ -e "$B/$f" ] || fail "bundle lacks $f"; done
ls "$B/images/$VER"/openwrt-*-emmc-preloader.bin "$B/images/$VER"/openwrt-*-emmc-bl31-uboot.fip >/dev/null || fail "bundle lacks TFTP bootloader files"
mkdir -p "$W/kf" "$W/tftp"; head -c 32 /dev/urandom >"$W/kf/factory-TEST.key"

cat >"$W/sim.py" <<'PYT'
import os, pty, re, sys, threading, time, tty, json, urllib.request, subprocess, csv, hmac, hashlib
W, B, VER, MODE = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
UPG = f"{B}/images/{VER}/bpi-r4-phase2-{VER}-squashfs-sysupgrade.itb"
MAC = "aa:bb:cc:11:22:33"
class Router(threading.Thread):
    def __init__(s):
        super().__init__(daemon=True)
        s.m, sl = pty.openpty(); tty.setraw(sl); s.path = os.ttyname(sl); s.sl = sl
        s.state, s.buf, s.env, s.led, s.label, s.cmds, s.erased = "off", b"", {}, "off", False, [], False
        s.settings_wiped = False
    def out(s, t): os.write(s.m, t.encode())
    def power_on(s):
        s.state = "countdown"
        s.out("\r\nNOTICE:  BL2: v2.10.0\r\nU-Boot 2024.10-OpenWrt\r\nHit any key to stop autoboot:  3 ")
    def run(s):
        while True:
            try: c = os.read(s.m, 4096)
            except OSError: return
            if s.state == "countdown" and c:
                s.state = "menu"; s.out("\r\n      1. Run default boot command.\r\n      0. Exit\r\n"); c = c[1:]
            s.buf += c
            while b"\n" in s.buf:
                l, s.buf = s.buf.split(b"\n", 1); s.line(l.decode().strip("\r"))
    def line(s, l):
        st = s.state
        if st == "menu":
            if l.strip() == "0": s.state = "uboot"; s.out("\r\nMT7988> ")
            return
        if st == "uboot":
            s.cmds.append(l); r = ""
            if l.startswith("part list"):
                end = "0x00e8f7ff" if MODE != "badgpt" else "0x00e8f900"
                r = f'Part\tStart LBA\tEnd LBA\t\tName\r\n  5     0x00020000      {end}      "production"'
            elif l.startswith("printenv ethaddr"): r = "ethaddr=4e:8f:40:ff:61:c8"
            elif "mmc erase 0x$pa 0x" in l:
                n = int(re.search(r"mmc erase 0x\$pa 0x([0-9a-f]+)", l).group(1), 16)
                s.erased = True
                # the settings overlay sits right after the image: erasing only the
                # header leaves the old settings (old root password) — .106 hardware run
                s.settings_wiped = n * 512 >= os.path.getsize(UPG) + 64 * 1024 * 1024
                r = f"MMC erase: dev # 0, block # 131072, count {n} ... {n} blocks erased: OK\r\nPROD_ERASED"
            elif l.startswith("run boot_tftp") or "boot_tftp_production" in l:
                if not s.erased: r = "OLD SYSTEM STILL BOOTABLE"
                r = (r + "\r\n" if r else "") + "Using ethernet@15100000 device\r\nTFTP from server 192.168.1.10; our IP address is 192.168.1.101\r\n####\r\nBytes transferred = 1234 (4d2 hex)\r\nMMC write: dev # 0, block # 0, count 1024 ... 1024 blocks written: OK"
            elif l.strip() == "reset":
                s.state = "booting"; threading.Thread(target=s.boot, daemon=True).start(); return
            s.out(l + "\r\n" + r + "\r\nMT7988> ")
            return
        if st == "login":
            if l == "root": s.state = "pw"; s.out("Password: ")
            else: s.out("\r\nnode-router login: ")
            return
        if st == "pw":
            s.state = "sh" if l == "knotsnode21" and s.settings_wiped else "login"
            s.out("\r\nroot@node-router:~# " if l == "knotsnode21" else "\r\nLogin incorrect\r\nnode-router login: ")
            return
        if st == "activate":
            s.state = "login"; s.out("\r\nnode-router login: "); return
        if st == "sh":
            body = l.split("echo __B''EGIN__; ", 1)[-1].rsplit("; echo __S''TATION__", 1)[0]
            s.cmds.append(body)
            r = ""
            if "S10boot" in body:
                s.bootpolls = getattr(s, "bootpolls", 0) + 1
                r = "BOOTING" if (MODE == "slowboot" and s.bootpolls < 3) else "BOOTED\r\nLAN_UP\r\nWEB_UP"
            elif "WIFI_RNODE" in body: r = "WIFI_RNODE\r\nWIFI_WPA2\r\nSETUP_WEB\r\nCAPTIVE_ON\r\nNAME_PUBLISHED"
            elif "product_version" in body: r = VER
            elif "/proc/cmdline" in body: r = "console=ttyS0 root=/dev/fit0 rootwait"
            elif "mmcblk0/device/name" in body: r = "8GTF4R"
            elif "/mnt/bitcoin" in body: r = "/dev/nvme0n1p1 /mnt/bitcoin ext4 rw 0 0"
            elif "fw_printenv -n ethaddr" in body: r = MAC
            elif "fw_printenv -n knots_secret" in body: r = s.env.get("knots_secret", "")
            elif body.startswith("fw_setenv knots_secret"): s.env["knots_secret"] = body.split()[-1]
            elif "setup-complete" in body: r = "fresh"
            elif "apply-password.sh" in body: r = "APPLIED_OK"
            elif "knots_unit_name" in body: r = "rnode-2233"
            elif "factory-label.sh on" in body: s.label = True; r = f"label-mode on rnode-2233 {MAC}"
            elif "factory-label.sh led on" in body: s.led = "on"; r = "label-led on rnode-2233"
            elif "factory-label.sh led off" in body: s.led = "off"
            elif "factory-label.sh off" in body: s.label = False; s.led = "off"
            elif body.strip() == "poweroff":
                if MODE == "stuck":            # shutdown hangs: nothing after the echo
                    s.out(l + "\r\n"); return
                s.state = "off"; s.powered_off = True
                s.out(l + "\r\nSTEP stop: bitcoind_ctl_stop done\r\n[ 99.1] EXT4-fs (nvme0n1p1): unmounting filesystem.\r\n[ 99.9] reboot: Power down\r\n")
                return
            s.out(l + "\r\n__BEGIN__\r\n" + r + ("\r\n" if r else "") + "__STATION__\r\nroot@node-router:~# ")
    def boot(s):
        time.sleep(1)
        s.out("\r\nStarting kernel ...\r\n[    0.000000] Linux version 6.6\r\nPlease press Enter to activate this console.\r\n")
        s.state = "activate"

r = Router(); r.start()
port = 18000 + os.getpid() % 1000
os.symlink(r.path, W + f"/alias-a-{MODE}"); os.symlink(r.path, W + f"/alias-b-{MODE}")   # one adapter, two names (by-path usb + usbv2)
env = dict(os.environ, RNODE_STATION_TEST="1", RNODE_STATION_PORTS=",".join([W + f"/alias-a-{MODE}", W + f"/alias-b-{MODE}"]), RNODE_TFTP_ROOT=W + "/tftp",
           KNOTS_FACTORY_DIR=W + "/kf", KNOTS_FACTORY_KEY_FILE=W + "/kf/factory-TEST.key",
           KNOTS_LABELS_CSV=W + "/kf/labels.csv",
           KNOTS_LABEL_PRINT_CMD="cp {png} " + W + "/printed-" + MODE + ".png",
           RNODE_STATION_IGNORE_PIDS=str(os.getpid()))
p = subprocess.Popen([sys.executable, B + "/factory/station/rnode_station.py", "--port", str(port)], env=env,
                     stdout=open(W + "/station.out", "w"), stderr=subprocess.STDOUT)
open(W + "/pids", "a").write(f"{p.pid}\n")
U = f"http://127.0.0.1:{port}"
def api(path, body=None):
    for _ in range(50):
        try:
            req = urllib.request.Request(U + path, data=json.dumps(body).encode() if body is not None else None,
                                         headers={"Content-Type": "application/json"})
            return json.load(urllib.request.urlopen(req, timeout=10))
        except urllib.error.URLError:
            time.sleep(0.2)
    raise SystemExit("station did not answer")
html = urllib.request.urlopen(U + "/").read().decode() if api("/api/state") else ""
assert "RNode Factory Station" in html
st = api("/api/state"); assert st["last_batch_size"] == 1, st
if MODE == "busy":      # a forgotten console holds the bay's port: say so, never start
    holder = subprocess.Popen([sys.executable, "-c", "import sys,time; f=open(sys.argv[1],'rb'); time.sleep(60)", r.path])
    time.sleep(0.5)
    det = api("/api/detect", {})
    try:
        req = urllib.request.Request(U + "/api/start", data=b'{"count": 1}', headers={"Content-Type": "application/json"})
        res = json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        res = json.load(e)
    holder.kill()
    print("BUSY", det["ports"][0]["seen"][:40], "|", res.get("error", "")[:70])
    p.terminate(); sys.exit(0)
det = api("/api/detect", {}); assert len(det["ports"]) == 1, det
res = api("/api/start", {"count": 1}); assert res.get("ok"), res
if MODE == "early":     # switched on before Start: station sees Linux, must ask for a power cycle, not fail
    time.sleep(1); r.out("\r\n[   12.0] procd: - init -\r\nPlease press Enter to activate this console.\r\n")
    time.sleep(3); st = api("/api/state"); b0 = st["bays"][0]
    print("EARLY", b0["status"], "|", b0["instruction"])
r.power_on()
pressed = False
end = time.time() + 150
while time.time() < end:
    st = api("/api/state")
    if r.led == "on" and not pressed:
        time.sleep(0.5); r.out(f"\r\nRNODE-IDENTIFY rnode-2233 {MAC}\r\n"); pressed = True
    if st["stage"] in ("complete", "stopped") or (st["bays"] and st["bays"][0]["status"] == "failed"):
        break
    time.sleep(0.5)
b = st["bays"][0] if st["bays"] else {}
print("STAGE", st["stage"], "STATUS", b.get("status"), "MSG", b.get("message"))
print("POWERED_OFF", getattr(r, "powered_off", False), "| STEPDONE", [x["done"] for x in b.get("steps", []) if x["id"] == "done"])
if MODE in ("ok", "early", "slowboot"):
    rows = list(csv.DictReader(open(W + "/kf/labels.csv")))
    key = open(W + "/kf/factory-TEST.key", "rb").read()
    n = int.from_bytes(hmac.new(key, MAC.encode(), hashlib.sha256).digest(), "big"); a = "abcdefghjkmnpqrstuvwxyz23456789"; c = []
    for _ in range(12): n, x = divmod(n, len(a)); c.append(a[x])
    want = "".join(c); want = f"{want[0:4]}-{want[4:8]}-{want[8:12]}"
    kid = "TEST-" + hashlib.sha256(key).hexdigest()[:8]
    print("SECRET", "match" if rows and "password" not in rows[-1] and rows[-1]["key_id"] == kid
          and want == r.env.get("knots_secret") else f"MISMATCH {rows} {r.env}")
    # lost sticker: recalculated from the factory key + MAC, printed now, logged without the password
    def recover(router):
        req = urllib.request.Request(f"http://127.0.0.1:{port}/api/recover", data=json.dumps({"router": router, "reason": "test"}).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            return json.load(urllib.request.urlopen(req))
        except urllib.error.HTTPError as e:
            return json.load(e)
    a = recover("2233"); b = recover(MAC); c = recover("rnode-9999")
    rec = list(csv.DictReader(open(W + "/kf/recoveries.csv")))
    print("RECOVER", a.get("unit"), a.get("printed"), os.path.exists(W + "/printed-" + MODE + ".png"),
          b.get("unit"), "notfound" if "not in the inventory" in c.get("error", "") else c,
          len(rec), "nopassword" if want not in open(W + "/kf/recoveries.csv").read() and "password" not in rec[0] else "LEAK")
    print("TFTP", sorted(os.listdir(W + "/tftp")))
    print("UBOOT", [c for c in r.cmds if c.startswith(("setenv serverip", "setenv ipaddr", "run boot_tftp")) or "boot_tftp_production" in c])
    print("STATE", json.load(open(W + "/kf/station-state.json")))
    print("ERASED_FIRST", r.erased and r.cmds.index(next(c for c in r.cmds if "mmc erase" in c)) < r.cmds.index(next(c for c in r.cmds if c.startswith("run boot_tftp_write_bl2"))))
    print("REPORT", list(csv.reader(open(st["batch_dir"] + "/report.csv")))[1:])
p.terminate()
PYT
out=$(timeout 150 python3 "$W/sim.py" "$W" "$B" "$VER" ok 2>&1) || fail "station run: $out $(tail -20 "$W/station.out")"
echo "$out" | grep -q "^STAGE complete STATUS ok" || fail "batch not complete: $out $(tail -30 "$W/station.out")"
echo "$out" | grep -q "^SECRET match" || fail "label secret / inventory (no password, key_id): $out"
echo "$out" | grep -q "^RECOVER rnode-2233 True True rnode-2233 notfound 2 nopassword$" \
	|| fail "lost-sticker recovery (by name and MAC, printed now, unknown refused, logged without password): $out"
echo "$out" | grep -q "openwrt-.*-emmc-preloader.bin" && echo "$out" | grep -q "bpi-r4-phase2-$VER-squashfs-sysupgrade.itb" || fail "TFTP root: $out"
echo "$out" | grep "^UBOOT" | grep -q "setenv serverip 192.168.1.10" && echo "$out" | grep "^UBOOT" | grep -q "setenv ipaddr 192.168.1.101" \
	&& [ "$(echo "$out" | grep '^UBOOT' | grep -o 'boot_tftp' | wc -l)" -ge 3 ] || fail "U-Boot TFTP commands: $out"
echo "$out" | grep -q "'last_batch_size': 1" || fail "batch size not remembered: $out"
echo "$out" | grep -qx "ERASED_FIRST True" || fail "old production must be erased before the TFTP writes: $out"
echo "$out" | grep -q "confirmed" || fail "sticker not confirmed: $out"
echo "$out" | grep -q "^POWERED_OFF True | STEPDONE \[True\]" && echo "$out" | grep -q "MSG ✔ off — ready to box" \
	|| fail "ready to box only after a clean shutdown: $out"
pass "station screen end to end (simulated router): detect → TFTP install → boot → verify → provision (HMAC secret; inventory without passwords) → sticker + WPS → complete; lost sticker recovered and printed; batch size remembered"
out=$(timeout 200 python3 "$W/sim.py" "$W" "$B" "$VER" slowboot 2>&1) || fail "station run (slow boot): $out"
echo "$out" | grep -q "^STAGE complete STATUS ok" || fail "router still booting must be waited for: $out"
pass "router still finishing its boot: the station waits (boot done, LAN, web) before verifying"
out=$(timeout 150 python3 "$W/sim.py" "$W" "$B" "$VER" early 2>&1) || fail "station run (early power): $out"
echo "$out" | grep -q "^EARLY running | Switch this router OFF" && echo "$out" | grep -q "^STAGE complete STATUS ok" \
	|| fail "router already running at Start: $out"
pass "router already running at Start: asks for a power cycle (no failure), then completes"
out=$(timeout 150 python3 "$W/sim.py" "$W" "$B" "$VER" badgpt 2>&1) || fail "station run (bad GPT): $out"
echo "$out" | grep -q "STATUS failed MSG ✘ eMMC partition table is not the 7391 layout" || fail "bad GPT not stopped: $out"
pass "a board with the wrong eMMC partition table is stopped before anything is written"
out=$(RNODE_SHUTDOWN_TIMEOUT=4 timeout 150 python3 "$W/sim.py" "$W" "$B" "$VER" stuck 2>&1) || fail "station run (stuck shutdown): $out"
echo "$out" | grep -q "^STAGE stopped STATUS failed MSG ✘ did not shut down" && ! echo "$out" | grep -q "ready to box" \
	|| fail "a router that does not shut down must never say ready to box: $out"
pass "a router that does not shut down is NOT 'ready to box' (bay failed, batch stopped)"
out=$(timeout 60 python3 "$W/sim.py" "$W" "$B" "$VER" busy 2>&1) || fail "station run (port busy): $out"
echo "$out" | grep -q "^BUSY IN USE by another program — close it.* | Bay 1: the serial port .* is in use by another" \
	|| fail "a serial port held by another program must be reported and the build refused: $out"
grep -q '"Retry bay " + b.num' "$B/factory/station/web/index.html" || fail "Retry button must sit in the What to do now box"
pass "a bay's serial port held by another program (forgotten console): reported, build refused; Retry button where the instruction is"
echo "ALL PASS: test-factory-station-app (T-STATION-APP)"
