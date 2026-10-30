#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-FACTORY-LABEL — stickers go on the right router (owner design 2026-10-24).
#  1. router (image BusyBox, docker + qemu): in label mode the WPS/reset button
#     only prints RNODE-IDENTIFY (no reboot, no factory reset); expired or no
#     label mode → the button works as before; blue LED on/off; led-status.sh
#     leaves the LEDs alone in label mode
#  2. station (factory/label-batch.py) against simulated bays on ptys: right
#     router pressed → confirmed, all bays leave label mode; wrong router
#     pressed → stop with MISMATCH, both flash, nothing confirmed after it
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
RFS="$ROOT/build/imagebuilder/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

# --- 1. router side --------------------------------------------------------
if [ -x "$RFS/bin/busybox" ] && [ -f "$RFS/lib/functions.sh" ] && command -v docker >/dev/null 2>&1 \
	&& [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] && docker image inspect alpine:3.20 >/dev/null 2>&1; then
	mkdir -p "$W/r"
	cp "$ROOT/files/etc/rc.button/reset" "$K/factory-label.sh" "$K/led-status.sh" "$W/r/"
	cat >"$W/r/t.sh" <<'EOF'
#!/bin/sh
# no set -u: OpenWrt's /lib/functions.sh (sourced by the handler) is not -u clean
T=/mnt/w; rm -rf $T; mkdir -p $T/bin $T/leds/blue $T/leds/green /mnt/res
for l in blue green; do echo none >$T/leds/$l/trigger; echo 0 >$T/leds/$l/brightness; done
printf '#!/bin/sh\necho REBOOT >>%s/actions\n' $T >$T/bin/reboot; chmod +x $T/bin/reboot
printf '#!/bin/sh\necho aa:bb:cc:dd:82:a2\n' >$T/bin/fw_printenv; chmod +x $T/bin/fw_printenv
export PATH=$T/bin:/usr/bin:/bin:/usr/sbin:/sbin KNOTS_LABEL_MODE_FILE=$T/mark KNOTS_UNIT_NAME=rnode-82a2 \
	KNOTS_LED_STATUS=$T/leds/green KNOTS_LED_ERROR=$T/leds/blue KNOTS_LABEL_TOOL=/mnt/r/factory-label.sh
press() { # SEEN — like procd: pressed, then released
	( ACTION=pressed; SEEN=0; . /mnt/r/reset ); echo "pressed rc=$?" >>$T/actions
	( ACTION=released; SEEN=$1; . /mnt/r/reset )
}
: >/dev/console
press 0;  echo "--- normal" >>$T/actions
sh /mnt/r/factory-label.sh on 600 >$T/on.out
# (in this chroot /dev/console is a plain file that each write replaces: snapshot it per press)
press 0; cp /dev/console $T/console1; press 7; cp /dev/console $T/console2; echo "--- label" >>$T/actions
sh /mnt/r/factory-label.sh led on >/dev/null
cat $T/leds/blue/trigger >$T/blue_on; cat $T/leds/green/trigger >$T/green_on
KNOTS_STATUS_JSON=/nonexistent sh /mnt/r/led-status.sh; cat $T/leds/blue/trigger >$T/blue_after_status
sh /mnt/r/factory-label.sh led off >/dev/null; cat $T/leds/blue/trigger >$T/blue_off
KNOTS_NOW=$(( $(date +%s) + 700 )) sh /mnt/r/factory-label.sh active && echo ACTIVE >$T/expired || echo EXPIRED >$T/expired
echo 1 >$T/mark; press 0; echo "--- expired" >>$T/actions
sh /mnt/r/factory-label.sh on 999999 >/dev/null; cat $T/mark >$T/mark_capped
cat $T/console1 $T/console2 >/mnt/res/console; cp $T/actions $T/on.out $T/blue_on $T/green_on $T/blue_after_status $T/blue_off $T/expired $T/mark_capped /mnt/res/
EOF
	out=$(docker run --rm -v "$RFS":/rootfs:ro -v "$W":/rootfs/mnt --tmpfs /rootfs/dev:rw,dev,size=64k \
		--tmpfs /rootfs/tmp:rw,size=8m alpine:3.20 \
		sh -c "chroot /rootfs /bin/busybox sh /mnt/r/t.sh; rc=\$?; chown -R $(id -u):$(id -g) /rootfs/mnt; exit \$rc" 2>&1) \
		|| fail "image run: $out"
	R="$W/res"
	# normal: reboot · label mode: two presses (short, 7 s) → nothing · expired: reboot
	want="pressed rc=0
REBOOT
--- normal
pressed rc=0
pressed rc=0
--- label
pressed rc=0
REBOOT
--- expired"
	[ "$(cat "$R/actions")" = "$want" ] || fail "button actions: $(cat "$R/actions")"
	grep -q '^label-mode on rnode-82a2 aa:bb:cc:dd:82:a2$' "$R/on.out" || fail "label mode on output: $(cat "$R/on.out")"
	[ "$(grep -c '^RNODE-IDENTIFY rnode-82a2 aa:bb:cc:dd:82:a2$' "$R/console")" = 2 ] || fail "identify on console: $(cat "$R/console")"
	grep -q 'timer' "$R/blue_on" && grep -q '\[none\]\|^none' "$R/green_on" || fail "led on: blue $(cat "$R/blue_on") green $(cat "$R/green_on")"
	grep -q 'timer' "$R/blue_after_status" || fail "led-status overrode the label LED"
	grep -q 'none' "$R/blue_off" || fail "led off: $(cat "$R/blue_off")"
	grep -qx EXPIRED "$R/expired" || fail "label mode must expire"
	[ $(( $(cat "$R/mark_capped") - $(date +%s) )) -le 7300 ] || fail "label mode longer than 2 h"
	pass "router (image BusyBox): label mode → WPS only identifies (no reboot/reset); expired/none → reboot as before; LEDs; capped + expiring"
else
	echo "SKIP router part: needs the Image Builder rootfs, docker and qemu binfmt"
fi

# --- 2. station side --------------------------------------------------------
python3 -c 'import serial' 2>/dev/null || { echo "SKIP station part: pyserial"; echo "ALL PASS: test-factory-label"; exit 0; }
# Passwords are recalculated from the factory key (owner, 2026-10-25); the
# inventory starts in the OLD format (password column) to cover the migration.
head -c 32 /dev/urandom >"$W/factory-TEST.key"
derive() { python3 -I -c 'import importlib.util,sys
s=importlib.util.spec_from_file_location("lb",sys.argv[3]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.derive_secret(sys.argv[1],sys.argv[2]))' "$W/factory-TEST.key" "$1" "$ROOT/factory/label-batch.py"; }
PW1=$(derive aa:bb:cc:00:00:01); PW2=$(derive aa:bb:cc:00:00:02)
printf '%s\n' "provisioned_utc,ethaddr,unit_name,wifi_ssid,password,product_version" \
	"2026-10-24T00:00:00Z,aa:bb:cc:00:00:01,rnode-0001,rnode,$PW1,x" \
	"2026-10-24T00:00:01Z,aa:bb:cc:00:00:02,rnode-0002,rnode,$PW2,x" >"$W/labels.csv"
export PW1 PW2 KNOTS_FACTORY_KEY_FILE="$W/factory-TEST.key"
cat >"$W/sim.py" <<'PYT'
import os, pty, sys, threading, time, subprocess, tty, csv, glob
ROOT, W, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
UNITS = [("rnode-0001", "aa:bb:cc:00:00:01", os.environ["PW1"]), ("rnode-0002", "aa:bb:cc:00:00:02", os.environ["PW2"])]
class Router(threading.Thread):
    def __init__(self, i):
        super().__init__(daemon=True)
        self.unit, self.mac, self.pw = UNITS[i]
        self.m, s = pty.openpty(); tty.setraw(s); self.path = os.ttyname(s); self.s = s
        self.state, self.buf, self.led, self.label, self.log = "login", b"", "off", False, []
    def out(self, t): os.write(self.m, t.encode())
    def run(self):
        while True:
            try: c = os.read(self.m, 4096)
            except OSError: return
            self.buf += c
            while b"\n" in self.buf:
                l, self.buf = self.buf.split(b"\n", 1); self.line(l.decode().strip("\r"))
    def line(self, l):
        if self.state == "login":
            if l == "root": self.state = "pw"; self.out("Password: ")
            else: self.out("\r\nnode-router login: ")
        elif self.state == "pw":
            if l == self.pw: self.state = "sh"; self.out("\r\nroot@node-router:~# ")
            else: self.state = "login"; self.out("\r\nLogin incorrect\r\nnode-router login: ")
        else:
            body = l.split("; echo")[0]
            r = ""
            if "factory-label.sh on" in body: self.label = True; r = f"label-mode on {self.unit} {self.mac}"
            elif "factory-label.sh led on" in body: self.led = "on"; r = f"label-led on {self.unit}"
            elif "factory-label.sh led off" in body: self.led = "off"; r = f"label-led off {self.unit}"
            elif "factory-label.sh off" in body: self.label = False; self.led = "off"; r = f"label-mode off {self.unit}"
            elif body == "exit": self.state = "login"; self.out("\r\nPlease press Enter to activate this console.\r\n"); return
            self.log.append(body)
            self.out(l + "\r\n" + r + "\r\n__BAY_DONE__\r\nroot@node-router:~# ")
    def press(self): self.out(f"\r\nRNODE-IDENTIFY {self.unit} {self.mac}\r\n")

rs = [Router(0), Router(1)]
for r in rs: r.start()
def operator():
    done = set()
    while True:
        for i, r in enumerate(rs):
            if r.led == "on" and i not in done:
                time.sleep(0.5)
                target = rs[i] if MODE == "ok" or i == 1 else rs[1]   # "wrong": bay 1's sticker confirmed on bay 2
                target.press(); done.add(i)
        time.sleep(0.1)
threading.Thread(target=operator, daemon=True).start()
p = subprocess.run([sys.executable, ROOT + "/factory/label-batch.py", "--bays", ",".join(r.path for r in rs),
                    "--labels-csv", W + "/labels.csv", "--out", W + "/out-" + MODE, "--press-timeout", "20", "--no-render"],
                   capture_output=True, text=True, timeout=120)
rep = list(csv.reader(open(glob.glob(W + f"/out-{MODE}/*/report.csv")[0])))
print("RC", p.returncode)
for row in rep[1:]: print("ROW", row[0], row[2], row[4])
print("LABEL", [r.label for r in rs], "LED", [r.led for r in rs])
inv = list(csv.DictReader(open(W + "/labels.csv")))
print("INVENTORY", "nopassword" if inv and "password" not in inv[0] else "HAS-PASSWORD",
      "keyid", ",".join(sorted(set(r["key_id"] for r in inv))))
sys.stderr.write(p.stdout[-1500:] + p.stderr[-1500:])
PYT
ok=$(python3 "$W/sim.py" "$ROOT" "$W" ok 2>"$W/ok.err") || fail "sim ok: $(cat "$W/ok.err")"
echo "$ok" | grep -qx 'RC 0' && [ "$(echo "$ok" | grep -c ' confirmed$')" = 2 ] \
	&& echo "$ok" | grep -qx "LABEL \[False, False\] LED \['off', 'off'\]" || fail "right routers: $ok $(cat "$W/ok.err")"
bad=$(python3 "$W/sim.py" "$ROOT" "$W" wrong 2>"$W/bad.err") || fail "sim wrong: $(cat "$W/bad.err")"
echo "$bad" | grep -qx 'RC 1' && echo "$bad" | grep -q '^ROW 1 rnode-0001 MISMATCH pressed rnode-0002' \
	&& ! echo "$bad" | grep -q 'confirmed$' && echo "$bad" | grep -q "LED \['on', 'on'\]" \
	|| fail "wrong router not stopped: $bad $(cat "$W/bad.err")"
echo "$ok" | grep -q '^INVENTORY nopassword keyid TEST-[0-9a-f]\{8\}$' || fail "inventory must lose its password column (key_id kept): $ok"
pass "station: right router → confirmed one by one, label mode left; wrong router → MISMATCH, batch stops, both flash; passwords recalculated, none stored"
echo "ALL PASS: test-factory-label (T-FACTORY-LABEL)"
