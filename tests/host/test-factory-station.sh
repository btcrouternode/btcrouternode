#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-FACTORY-STATION — production laptop tooling (2026-10-24).
#  - install-emmc-from-sd.sh installs the station ssh key through the serial
#    console (login root + factory password, 88-knots-ttylogin) — driven here
#    against a simulated router console on a pty: factory password, wrong
#    password (refused, no key), pre-.99 auto-login shell, key text intact;
#    the key is removed at the end of phase 4 and ssh never records host keys
#  - station-setup.sh / make-station-bundle.sh: bundle has the scripts, the
#    expected version and verified images, and no secrets
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
IE="$ROOT/factory/install-emmc-from-sd.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
python3 -c 'import serial' 2>/dev/null || { echo "SKIP: pyserial missing"; exit 0; }

# static
grep -q 'remove_station_key() or die' "$IE" || fail "phase 4 must remove the station key before shipping"
grep -q "UserKnownHostsFile=/dev/null" "$IE" || fail "ssh must not record per-medium host keys"
grep -q 'KNOTS_FACTORY_PASS' "$IE" || fail "console login must use KNOTS_FACTORY_PASS"
grep -q 'rnode-factory-station' "$ROOT/factory/station-setup.sh" || fail "station key comment"
pass "station key: installed via console, removed in phase 4; no host-key records"

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
sed -n "/<< 'PY'\$/,/^PY\$/p" "$IE" | sed '1d;$d' | sed '/^main()$/d' >"$W/ie.py"
ssh-keygen -q -t ed25519 -N '' -C rnode-factory-station -f "$W/station" || fail "ssh-keygen"
python3 - "$W" <<'PYT' || exit 1
import os, pty, sys, threading, time, serial
W = sys.argv[1]
sys.argv = ["x", "/dev/null", "115200", "root@192.0.2.1", "8GTF4R", "", "1", "1", "4"]
os.environ["KNOTS_STATION_KEY"] = W + "/station"
os.environ["KNOTS_FACTORY_PASS"] = "factorypw"
src = open(W + "/ie.py").read()
g = {"__name__": "ie"}
exec(compile(src, "ie.py", "exec"), g)
PUB = open(W + "/station.pub").read().strip()

class Console(threading.Thread):
    """Simulated router console: askconsole → login → ash."""
    def __init__(self, fd, autologin=False):
        super().__init__(daemon=True)
        self.fd, self.state, self.buf = fd, ("shell" if autologin else "activate"), b""
        self.keys, self.alive = [], True
    def out(self, s): os.write(self.fd, s.encode())
    def run(self):
        while self.alive:
            try: c = os.read(self.fd, 4096)
            except OSError: return
            self.buf += c
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                self.line(line.decode().strip("\r"))
    def line(self, l):
        if self.state == "activate":
            self.state = "login"; self.out("\r\n\r\nnode-router login: ")
        elif self.state == "login":
            self.state = "password" if l == "root" else "login"
            self.out("Password: " if l == "root" else "\r\nnode-router login: ")
        elif self.state == "password":
            if l == "factorypw":
                self.state = "shell"; self.out("\r\nroot@node-router:~# ")
            else:
                self.state = "login"; self.out("\r\nLogin incorrect\r\nnode-router login: ")
        elif self.state == "shell":
            if l == "exit":
                self.state = "activate"; self.out("\r\nPlease press Enter to activate this console.\r\n")
            elif "authorized_keys" in l:
                if PUB in l: self.keys.append(PUB)
                self.out(l + "\r\nSTATION_KEY_OK\r\nroot@node-router:~# ")
            else:
                self.out("\r\nroot@node-router:~# ")

def run(autologin=False, pw="factorypw"):
    os.environ["KNOTS_FACTORY_PASS"] = pw
    g["FACTORY_PASS"] = pw
    m, s = pty.openpty()
    import tty; tty.setraw(s)
    con = Console(m, autologin); con.start()
    ser = serial.Serial(os.ttyname(s), 115200, timeout=0.1)
    try:
        ok = g["console_install_station_key"](ser)
    finally:
        con.alive = False; ser.close()
    return ok, con

fails = []
ok, con = run()
if not ok or con.keys != [PUB]: fails.append(f"factory password: ok={ok} keys={len(con.keys)}")
if con.state != "activate": fails.append(f"console left logged in (state {con.state})")
ok, con = run(pw="wrong")
if ok or con.keys: fails.append(f"wrong password: ok={ok} keys={len(con.keys)}")
ok, con = run(autologin=True)
if not ok or con.keys != [PUB]: fails.append(f"auto-login shell: ok={ok} keys={len(con.keys)}")
if fails:
    print("FAIL: " + "; ".join(fails)); sys.exit(1)
PYT
pass "console login on a simulated router: factory password installs the exact key and logs out; wrong password installs nothing; pre-.99 auto-login works"

# bundle (needs a built SD image)
OV=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env"); KV=$(sed -n 's/^KNOTS_VER := //p' "$ROOT/build/version.env")
BN=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env"); VER="$OV.$KV.$BN"
if [ -f "$ROOT/bin/targets/mediatek/filogic/bpi-r4-phase2-$VER-sdcard.img.gz" ]; then
	sh "$ROOT/factory/make-station-bundle.sh" "$W/bundle" >/dev/null || fail "make-station-bundle"
	B="$W/bundle/rnode-factory"
	for f in factory/install-emmc-from-sd.sh factory/provision-secret.sh factory/flash-sd.sh factory/station-setup.sh \
		factory/PRODUCTION.md build/version.env "images/$VER/bpi-r4-phase2-$VER-sdcard.img.gz" "images/$VER/bpi-r4-phase2-$VER.sha256"; do
		[ -e "$B/$f" ] || fail "bundle lacks $f"
	done
	find "$B" \( -name '*.sec' -o -name '*.key' -o -name 'labels*.csv' -o -name 'station_ed25519*' \) | grep -q . && fail "secret in bundle"
	KNOTS_FACTORY_DIR="$W/kf" bash "$B/factory/station-setup.sh" --check >"$W/check.txt" 2>&1 || fail "station-setup --check: $(cat "$W/check.txt")"
	[ ! -e "$W/kf/station_ed25519" ] && grep -q "station.env written" "$W/check.txt" || fail "--check must not create keys"
	pass "station bundle: scripts, runbook, version, verified images, no secrets; setup --check creates no keys"
else
	echo "SKIP bundle part: no SD image for $VER (make image)"
fi
echo "ALL PASS: test-factory-station (T-FACTORY-STATION)"
