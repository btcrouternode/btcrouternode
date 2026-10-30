#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""RNode Factory Station — web screen that builds a batch of routers.

Runs on the factory laptop; open http://127.0.0.1:8099/ in a browser.

Per router ("bay" = one USB serial adapter on a fixed USB port):
  power on (DIP eMMC) → catch U-Boot → check the eMMC partition table (7391)
  → TFTP-write preloader, BL31+U-Boot FIP and the production image (no SD)
  → reboot into production → log in on the console, verify version / eMMC
  → provision over the console: MAC → label password (factory key) → root +
    Wi-Fi → labels.csv
Then stickers one bay at a time: PNG on screen, that router's blue LED
flashes, the operator presses ITS WPS button → confirmed (wrong router stops).

Writing the FIP resets the board's U-Boot env, so a re-used board comes back
like a new one (new MAC, no old secret). Boards whose eMMC has no working
U-Boot (brand-new, blank) still need the NAND route — not handled here yet.

Station network: this laptop has a fixed address (STATION_IP) on the cable to
the bays; each bay's U-Boot gets 192.168.1.(100+bay) for its TFTP transfers.
TFTP root: TFTP_ROOT (tftpd-hpa, factory/station-setup.sh).
"""
import argparse, csv, datetime, glob, hashlib, hmac, http.server, importlib.util, json, os, re
import shutil, socketserver, subprocess, sys, threading, time, traceback, urllib.parse

import serial

HERE = os.path.dirname(os.path.abspath(__file__))
FACTORY = os.path.dirname(HERE)
BUNDLE = os.path.dirname(FACTORY)
KF = os.path.expanduser(os.environ.get("KNOTS_FACTORY_DIR", "~/knots-factory"))
STATE_FILE = os.path.join(KF, "station-state.json")
STATION_IP = os.environ.get("RNODE_STATION_IP", "192.168.1.10")
TFTP_ROOT = os.environ.get("RNODE_TFTP_ROOT", "/srv/tftp")
RECOVERED_DIR = os.path.join(KF, "recovered")             # replacement stickers (lost sticker)
PRINT_CMD = os.environ.get("KNOTS_LABEL_PRINT_CMD", "")     # "{png}" = file; empty = PNG only (dry run)
FACTORY_PASS = os.environ.get("KNOTS_FACTORY_PASS", "knotsnode21")
GPT_PRODUCTION_END = "0x00e8f7ff"          # 7391 MiB production (F28)
EMMC_NAME = os.environ.get("EMMC_NAME", "8GTF4R")
UBOOT_PROMPT = re.compile(r"(MT7988>|=>)\s*$")
LABEL_TOOL = "/usr/libexec/knots/factory-label.sh"
IDENT_RX = re.compile(r"RNODE-IDENTIFY (\S+) ([0-9a-f:]*)")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
TEST_MODE = os.environ.get("RNODE_STATION_TEST") == "1"   # host tests: simulated bays, no network checks

# label rendering is shared with factory/label-batch.py
_spec = importlib.util.spec_from_file_location("label_batch", os.path.join(FACTORY, "label-batch.py"))
label_batch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(label_batch)

SHUTDOWN_TIMEOUT = int(os.environ.get("RNODE_SHUTDOWN_TIMEOUT", "300"))   # poweroff: node stop + M.2 unmount (~1–2 min)
STEPS = ["power", "check", "tftp", "boot", "verify", "provision", "label", "done"]
STEP_TITLES = {
    "power": "Power on, catch U-Boot", "check": "eMMC partition table", "tftp": "TFTP write: preloader, U-Boot, production",
    "boot": "Boot production", "verify": "Log in and verify", "provision": "Provision label password",
    "label": "Sticker on the right router", "done": "Shut down — ready to box",
}


def now():
    return datetime.datetime.now().strftime("%H:%M:%S")


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(st):
    os.makedirs(KF, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(st, f, indent=1)
    os.replace(tmp, STATE_FILE)


def read_version():
    env = open(os.path.join(BUNDLE, "build", "version.env")).read()
    get = lambda k: re.search(rf"^{k} := (\S+)", env, re.M).group(1)
    return f"{get('OPENWRT_VER')}.{get('KNOTS_VER')}.{get('BUILD_NUM')}"


def image_set(ver):
    """The four files the TFTP install needs, from images/<ver>/ of the bundle."""
    d = os.path.join(BUNDLE, "images", ver)
    ov = ver.split(".29.")[0] if ".29." in ver else ver.rsplit(".", 3)[0]
    files = {
        "bl2": glob.glob(os.path.join(d, "openwrt-*-bananapi_bpi-r4-emmc-preloader.bin")),
        "fip": glob.glob(os.path.join(d, "openwrt-*-bananapi_bpi-r4-emmc-bl31-uboot.fip")),
        "upg": [os.path.join(d, f"bpi-r4-phase2-{ver}-squashfs-sysupgrade.itb")],
    }
    out = {}
    for k, v in files.items():
        v = [p for p in v if os.path.isfile(p)]
        if not v:
            raise RuntimeError(f"bundle has no {k} image in {d} (make factory-station)")
        out[k] = v[0]
    return out


def prod_erase_blocks(image):
    """512-byte blocks to erase at the start of the production partition: the
    image plus 64 MiB, so the old settings overlay that follows it is gone too."""
    return (os.path.getsize(image) + 511) // 512 + 0x20000


def port_users(port):
    """Other programs that have this serial port open, e.g. a forgotten console
    (2026-10-26: an old miniterm on the bay's port broke a build with "multiple
    access on port"). Returns ["PID command", ...]; never this station."""
    real, out = os.path.realpath(port), []
    # tests: the simulated router holds its own end of the pty (a real one does not)
    skip = {os.getpid()} | {int(x) for x in os.environ.get("RNODE_STATION_IGNORE_PIDS", "").split(",") if x.isdigit()}
    for d in glob.glob("/proc/[0-9]*"):
        pid = int(os.path.basename(d))
        if pid in skip:
            continue
        try:
            fds = os.listdir(d + "/fd")
        except OSError:
            continue
        for fd in fds:
            try:
                if os.readlink(f"{d}/fd/{fd}") == real:
                    cmd = open(d + "/cmdline", "rb").read().replace(b"\0", b" ").decode(errors="replace").strip()
                    out.append(f"{pid} {cmd[:80]}")
                    break
            except OSError:
                continue
    return out


# One source for the sticker password (factory/label-batch.py): HMAC(factory key, MAC).
derive_secret = label_batch.derive_secret


class Console:
    """One bay's serial console: U-Boot and Linux. Keeps a log tail and every
    RNODE-IDENTIFY (WPS press in label mode) it sees."""

    def __init__(self, port, logpath):
        self.port = port
        self.ser = serial.Serial(port, 115200, timeout=0.1)
        self.log = open(logpath, "a", buffering=1)
        self.tail = []
        self.idents = []
        self.lock = threading.Lock()
        self._partial = ""

    def _feed(self, text):
        self.log.write(text)
        self.idents += [m.group(1) for m in IDENT_RX.finditer(text)]
        text = self._partial + ANSI.sub("", text).replace("\r", "")
        lines = text.split("\n")
        self._partial = lines.pop()
        for l in lines:
            if l.strip():
                self.tail.append(l[:160])
        del self.tail[:-60]

    def read(self, t, until=None, rx=None):
        end, acc = time.time() + t, ""
        while time.time() < end:
            c = self.ser.read(4096)
            if c:
                s = c.decode("utf-8", "replace")
                acc += s
                self._feed(s)
                clean = ANSI.sub("", acc)
                if (until and any(u in clean for u in until)) or (rx and rx.search(clean[-300:])):
                    time.sleep(0.2)
                    more = self.ser.read(65536).decode("utf-8", "replace")
                    acc += more
                    self._feed(more)
                    break
        return ANSI.sub("", acc).replace("\r", "")

    def write(self, s, chunk=24, gap=0.02):
        b = s.encode("latin-1")
        for i in range(0, len(b), chunk):
            self.ser.write(b[i:i + chunk]); self.ser.flush(); time.sleep(gap)

    # --- U-Boot ---
    def uboot(self, cmd, t=60):
        self.read(0.2)
        self.write(cmd + "\n")
        return self.read(t, rx=UBOOT_PROMPT)

    # --- Linux shell (logged in) ---
    def sh(self, cmd, t=20):
        """Run one command; returns only its output (the console echoes the
        typed line, so the output is taken between two markers the echo
        cannot contain: the typed text has __B''EGIN__, the output __BEGIN__)."""
        self.read(0.2)
        self.write("echo __B''EGIN__; " + cmd + "; echo __S''TATION__\n")
        out = self.read(t, until=["__STATION__"])
        if "__BEGIN__" in out:
            out = out.split("__BEGIN__", 1)[1]
        return out.split("__STATION__")[0].strip("\n")

    def login(self, passwords, t=20):
        self.write("\n"); out = self.read(3, until=["login:", "# "])
        if "activate" in out and "login:" not in out:
            self.write("\n"); out += self.read(3, until=["login:", "# "])
        if "login:" not in out:
            return "# " in out
        for pw in passwords:
            self.write("root\n"); self.read(4, until=["assword"])
            self.write(pw + "\n")
            out = self.read(t, until=["# ", "incorrect"])
            if "incorrect" not in out.lower() and "# " in out:
                return True
            self.read(5, until=["login:"])
        return False

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass


class Bay(threading.Thread):
    def __init__(self, station, num, port):
        super().__init__(daemon=True)
        self.st, self.num, self.port = station, num, port
        self.step = "power"
        self.status = "waiting"           # waiting | running | ok | failed
        self.message = "Waiting to start"
        self.instruction = ""
        self.unit = self.mac = self.secret = None
        self.label_png = None
        self.done = {s: False for s in STEPS}
        self.con = None
        self.retry_event = threading.Event()

    # --- reporting ---
    def say(self, msg, instruction=None):
        self.message = msg
        if instruction is not None:
            self.instruction = instruction
        self.st.event(f"bay {self.num}: {msg}")

    def fail(self, msg):
        self.status = "failed"
        self.say("✘ " + msg, f"Fix the problem, then click Retry bay {self.num}.")
        raise BayFailed(msg)

    def finish_step(self, s):
        self.done[s] = True

    def snapshot(self):
        return {
            "num": self.num, "port": self.port, "step": self.step, "status": self.status,
            "message": self.message, "instruction": self.instruction, "unit": self.unit, "mac": self.mac,
            "steps": [{"id": s, "title": STEP_TITLES[s], "done": self.done[s], "current": s == self.step} for s in STEPS],
            "log": (self.con.tail[-14:] if self.con else []),
            "label_png": os.path.basename(self.label_png) if self.label_png else None,
        }

    # --- the build ---
    def run(self):
        while True:
            try:
                self.status = "running"
                self.build()
                return
            except BayFailed:
                pass
            except Exception as e:
                self.status = "failed"
                if "multiple access" in str(e) or port_users(self.port):
                    self.say("✘ another program is reading this bay's serial port: "
                             + "; ".join(port_users(self.port)[:1] or ["(it has closed now)"]),
                             f"Close that console (Ctrl + ] in miniterm), then click Retry bay {self.num}.")
                else:
                    self.say(f"✘ unexpected error: {e}", f"Click Retry bay {self.num}.")
                self.st.event(traceback.format_exc()[-800:])
            self.retry_event.clear()
            self.retry_event.wait()

    def build(self):
        if not self.con:
            self.con = Console(self.port, os.path.join(self.st.batch_dir, f"bay{self.num}-console.log"))
        if not self.done["power"]:
            self.step_power()
        if not self.done["check"]:
            self.step_check()
        if not self.done["tftp"]:
            self.step_tftp()
        if not self.done["boot"]:
            self.step_boot()
        if not self.done["verify"]:
            self.step_verify()
        if not self.done["provision"]:
            self.step_provision()
        self.step = "label"
        self.status = "ok"
        self.say(f"built and provisioned: {self.unit}", "Waiting for the sticker step.")

    def step_power(self):
        self.step = "power"
        self.say("waiting for power-on",
                 "Set DIP SW3 to A=1 B=0 (eMMC), no SD card, then POWER ON this router.")
        c = self.con
        end = time.time() + 600
        acc = ""
        while time.time() < end:
            acc += c.read(1.0)
            clean = acc[-3000:]
            if UBOOT_PROMPT.search(clean[-200:]):
                break
            if "Hit any key" in clean or "stop autoboot" in clean:
                c.write(" ")
                menu = c.read(3)
                if UBOOT_PROMPT.search(menu[-200:]) is None:
                    c.write("0\n")             # boot menu: 0 = Exit to the shell
                    c.read(6, rx=UBOOT_PROMPT)
                break
            if "Please press Enter to activate" in clean or "login:" in clean or "Linux version" in clean[-400:]:
                # already running (switched on too early, or no countdown): not an error —
                # ask for a power cycle and keep watching for U-Boot
                acc = ""
                self.say("router is already running Linux — the U-Boot countdown was missed",
                         "Switch this router OFF, wait 5 seconds, then switch it ON again.")
        else:
            self.fail("no U-Boot seen on this bay in 10 minutes — is it powered and is the serial cable on the UART?")
        out = c.uboot("version", 10)
        if not UBOOT_PROMPT.search(out[-200:]):
            self.fail("could not reach the U-Boot prompt")
        self.say("U-Boot caught", "")
        self.finish_step("power")

    def step_check(self):
        self.step = "check"
        c = self.con
        c.uboot("mmc dev 0", 10)
        out = c.uboot("part list mmc 0", 20)
        m = re.search(r"\s5\s+(0x[0-9a-f]+)\s+(0x[0-9a-f]+)\s+\"production\"", out)
        if not m:
            self.fail("no 'production' partition on the eMMC — this board needs the NAND route (blank eMMC)")
        if m.group(2) != GPT_PRODUCTION_END:
            self.fail(f"eMMC partition table is not the 7391 layout (production ends {m.group(2)}, want {GPT_PRODUCTION_END})")
        mac = re.search(r"ethaddr=([0-9a-fA-F:]{17})", c.uboot("printenv ethaddr", 10))
        self.say(f"partition table OK (7391); current MAC {mac.group(1) if mac else '?'} — will be renewed")
        self.finish_step("check")

    def step_tftp(self):
        self.step = "tftp"
        c = self.con
        ip = f"192.168.1.{100 + self.num}"
        if not TEST_MODE:                      # link is up now (router on): wait for the station address
            for _ in range(30):
                if subprocess.run(["sh", "-c", f"ip -4 addr | grep -q 'inet {STATION_IP}/'"]).returncode == 0:
                    break
                time.sleep(1)
            else:
                self.fail(f"this laptop has no address {STATION_IP} on the cable to the routers — is the LAN cable "
                          "in the router's LAN port and the rnode-factory network profile active?")
        for cmd in (f"setenv ipaddr {ip}", f"setenv serverip {STATION_IP}",
                    f"setenv bootfile_bl2 {os.path.basename(self.st.images['bl2'])}",
                    f"setenv bootfile_fip {os.path.basename(self.st.images['fip'])}",
                    f"setenv bootfile_upg {os.path.basename(self.st.images['upg'])}"):
            c.uboot(cmd, 10)
        # First erase the OLD system: the image area plus the start of the
        # settings area behind it. The router's settings (root password, Wi-Fi,
        # Setup done) live in an F2FS overlay ("fitrw") right after the image in
        # the same partition — .106 station run: only the 4 MiB header was
        # erased, the new image booted with router B's old settings and the
        # factory password was refused. From here a failed or stopped run
        # leaves the board in U-Boot instead of booting old firmware; U-Boot,
        # the partition table and the env stay, so Retry just continues by TFTP.
        self.say("erasing the old production system and its settings")
        out = c.uboot(f"part start mmc 0 production pa && mmc erase 0x$pa 0x{prod_erase_blocks(self.st.images['upg']):x}"
                      " && echo PROD_ER''ASED", 300)
        if "PROD_ERASED" not in out.split("PROD_ER''ASED")[-1]:
            self.fail("could not erase the old production system: " + out.strip().splitlines()[-1])
        for name, cmd, what in (
                ("preloader", "run boot_tftp_write_bl2", "BL2 preloader"),
                ("U-Boot", "run boot_tftp_write_fip", "BL31 + U-Boot FIP"),
                ("production", "setenv noboot 1; setenv replacevol 1; run boot_tftp_production; setenv noboot; setenv replacevol",
                 "production image")):
            self.say(f"TFTP: {what} from {STATION_IP} …")
            out = c.uboot(cmd, 900)
            if "Bytes transferred" not in out:
                self.fail(f"TFTP of the {what} failed — check the station address {STATION_IP}, the cable and the TFTP server\n"
                          + "\n".join(out.strip().splitlines()[-4:]))
            if "written: OK" not in out and "blocks written" not in out:
                self.fail(f"writing the {what} to the eMMC did not report OK")
            if re.search(r"\b(ERROR|Error|FAILED|failed)\b", out.split("Bytes transferred")[-1]):
                self.fail(f"error while writing the {what}: " + out.strip().splitlines()[-1])
            self.say(f"{what} written")
        self.finish_step("tftp")

    def step_boot(self):
        self.step = "boot"
        c = self.con
        self.say("rebooting into production (first boot takes 2–4 min)")
        c.write("reset\n")
        out = c.read(720, until=["Please press Enter to activate", "login:"])
        if "Please press Enter" not in out and "login:" not in out:
            self.fail("production did not reach the console login in 12 minutes")
        if "Failed to initialize GPT" in out or "TFTP from server" in out:
            self.fail("the board fell back to TFTP / GPT panic — production not bootable")
        time.sleep(20)                         # let first-boot services settle
        self.finish_step("boot")

    def step_verify(self):
        self.step = "verify"
        c = self.con
        if not c.login([FACTORY_PASS]):
            for s_ in ("power", "check", "tftp", "boot"):
                self.done[s_] = False          # Retry = the whole install again
            self.fail("console login with the factory password failed — the router kept settings from before "
                      "(old password). Power it off, press Retry and power it on: the station erases them again.")
        # The console answers long before the router is usable: wait until the
        # boot sequence (S10boot, incl. first-boot scripts) has really finished
        # and the LAN is up — .104 dry run: a unit was "done" while its boot was
        # still blocked (no LAN, no Wi-Fi).
        self.say("waiting for the router to finish starting up")
        end = time.time() + 900
        while True:
            st = c.sh('pgrep -f "S10boot boot" >/dev/null && echo BOOTING || echo BOOTED; '
                      'ip -4 addr show br-lan 2>/dev/null | grep -q "inet " && echo LAN_UP; pidof nginx >/dev/null && echo WEB_UP', 20)
            if "BOOTED" in st and "LAN_UP" in st and "WEB_UP" in st:
                break
            if time.time() > end:
                self.fail("the router did not finish starting up in 15 minutes (" + " ".join(st.split()) + ")")
            time.sleep(10)
        checks = []
        ver = c.sh("cat /etc/knots/product_version").strip().splitlines()
        ver = ver[-1].strip() if ver else ""
        checks.append(("version " + self.st.version, ver == self.st.version, ver))
        checks.append(("root=/dev/fit0", "root=/dev/fit0" in c.sh("cat /proc/cmdline"), ""))
        mmc = c.sh("cat /sys/class/block/mmcblk0/device/name").strip().splitlines()
        checks.append((f"eMMC {EMMC_NAME}", bool(mmc) and mmc[-1].strip() == EMMC_NAME, mmc[-1] if mmc else ""))
        bad = [f"{n} ({d})" if d else n for n, ok, d in checks if not ok]
        if bad:
            self.fail("verification failed: " + ", ".join(bad))
        m2 = " /mnt/bitcoin " in c.sh("grep ' /mnt/bitcoin ' /proc/mounts")
        self.say("verified: version, root, eMMC" + ("" if m2 else " — NOTE: M.2 not mounted"))
        self.finish_step("verify")

    def step_provision(self):
        self.step = "provision"
        c = self.con
        mac = c.sh("fw_printenv -n ethaddr").strip().splitlines()
        mac = mac[-1].strip().lower() if mac else ""
        if not re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
            self.fail(f"could not read the MAC (got {mac!r})")
        secret = derive_secret(self.st.factory_key, mac)
        existing = c.sh("fw_printenv -n knots_secret 2>/dev/null").strip().splitlines()
        existing = existing[-1].strip() if existing else ""
        if existing and existing != secret:
            self.fail("this board already has a DIFFERENT label secret — not overwriting (relabel by hand)")
        if existing != secret:
            c.sh(f"fw_setenv knots_secret {secret}")
        got = c.sh("fw_printenv -n knots_secret").strip().splitlines()
        if not got or got[-1].strip() != secret:
            self.fail("the label secret did not stick in the U-Boot env")
        fresh = "fresh" in c.sh("[ -f /etc/knots/setup-complete ] || [ -f /etc/knots/setup-password-done ] && echo configured || echo fresh")
        if fresh:
            out = c.sh(". /usr/libexec/knots/setup-lib.sh; knots_factory_secret >/dev/null && "
                       "/usr/libexec/knots/factory/apply-password.sh && rm -f /etc/knots/wifi-default-done && "
                       "/usr/libexec/knots/wifi-default-enable.sh && echo AP''PLIED_OK", 90)
            if "APPLIED_OK" not in out:
                self.fail("applying the label password to root / Wi-Fi failed")
        unit = c.sh(". /usr/libexec/knots/unit-name.sh; knots_unit_name").strip().splitlines()
        self.unit = unit[-1].strip() if unit else "rnode-" + mac.replace(":", "")[-4:]
        # Customer view, exactly what the sticker promises: Wi-Fi rnode up with
        # WPA2, the Setup page answering, first-use captive portal on, the unit
        # name published over mDNS.
        self.say("checking what the customer will see (Wi-Fi, Setup, name)")
        cust = ""
        for _ in range(12):
            cust = c.sh('iwinfo 2>/dev/null | grep -q \'ESSID: "rnode"\' && echo WIFI_RNODE; '
                        'iwinfo 2>/dev/null | grep -q "WPA2 PSK" && echo WIFI_WPA2; '
                        'wget -qO- -T 5 http://127.0.0.1/api/alive 2>/dev/null | grep -q alive && echo SETUP_WEB; '
                        '/usr/libexec/knots/captive-portal.sh status 2>/dev/null | grep -qx on && echo CAPTIVE_ON; '
                        'pgrep -f "avahi-publish -a -R" >/dev/null && echo NAME_PUBLISHED', 30)
            if all(k in cust for k in ("WIFI_RNODE", "WIFI_WPA2", "SETUP_WEB", "CAPTIVE_ON", "NAME_PUBLISHED")):
                break
            time.sleep(10)
        missing = [n for k, n in (("WIFI_RNODE", "Wi-Fi rnode"), ("WIFI_WPA2", "WPA2"), ("SETUP_WEB", "Setup page"),
                                  ("CAPTIVE_ON", "sign-in (captive) portal"), ("NAME_PUBLISHED", f"{self.unit}.local"))
                   if k not in cust]
        if missing:
            self.fail("customer view not ready: " + ", ".join(missing))
        self.mac, self.secret = mac, secret
        self.st.append_label(self)
        self.say(f"provisioned {self.unit} (password applied: {'yes' if fresh else 'already set up'})")
        self.finish_step("provision")


class BayFailed(Exception):
    pass


class Station:
    def __init__(self):
        self.lock = threading.Lock()
        self.events = []
        self.stage = "setup"            # setup | detected | building | labelling | complete
        self.bays = []
        self.ports = []
        self.batch_dir = None
        self.version = read_version()
        self.images = {}
        self.factory_key = os.environ.get("KNOTS_FACTORY_KEY_FILE") or ""
        self.labels_csv = os.environ.get("KNOTS_LABELS_CSV") or os.path.join(KF, "labels.csv")
        self.state = load_state()
        self.label_bay = None
        self.label_msg = ""
        self.problems = []

    def event(self, msg):
        with self.lock:
            self.events.append(f"{now()} {msg}")
            del self.events[:-200]
        if self.batch_dir:
            with open(os.path.join(self.batch_dir, "events.log"), "a") as f:
                f.write(f"{now()} {msg}\n")

    # --- environment checks shown on the start screen ---
    def preflight(self):
        p = []
        if not self.factory_key or not os.path.isfile(self.factory_key):
            p.append("No factory key (run factory/station-setup.sh; TEST key for a dry run).")
        else:
            try:
                if label_batch.migrate_inventory(self.labels_csv, self.factory_key):
                    self.event("labels.csv: passwords removed (recalculated from the factory key when needed)")
            except Exception as e:
                p.append(f"labels.csv could not be updated: {e}")
        try:
            self.images = image_set(self.version)
        except Exception as e:
            p.append(str(e))
        if not os.path.isdir(TFTP_ROOT) or not os.access(TFTP_ROOT, os.W_OK):
            p.append(f"TFTP root {TFTP_ROOT} missing or not writable (run factory/station-setup.sh).")
        if TEST_MODE:
            self.problems = p
            return p
        # The address only exists while the cable has a link — and the routers are
        # OFF before a batch starts. A configured NetworkManager profile is enough
        # here; the TFTP step waits for the address once the router is on.
        has_ip = subprocess.run(["sh", "-c", f"ip -4 addr | grep -q 'inet {STATION_IP}/'"]).returncode == 0
        has_profile = subprocess.run(["sh", "-c", "nmcli -t -f NAME con show 2>/dev/null | grep -qx rnode-factory"]).returncode == 0
        if not has_ip and not has_profile:
            p.append(f"No station address {STATION_IP} and no 'rnode-factory' network profile (run factory/station-setup.sh).")
        tftpd = subprocess.run(["sh", "-c", "ss -lun 2>/dev/null | grep -q ':69 '"]).returncode == 0
        if not tftpd:
            p.append("No TFTP server listening on UDP port 69 (tftpd-hpa; factory/station-setup.sh).")
        self.problems = p
        return p

    def detect(self):
        override = os.environ.get("RNODE_STATION_PORTS", "")
        ports = (override.split(",") if override else
                 sorted(glob.glob("/dev/serial/by-path/*")) or sorted(glob.glob("/dev/ttyUSB*")))
        found, seen = [], set()
        for p in ports:
            real = os.path.realpath(p)
            if real in seen:                 # one adapter can appear under several by-path names
                continue
            seen.add(real)
            info = {"port": p, "dev": os.path.realpath(p), "seen": "no output (router off?)"}
            busy = port_users(p)
            if busy:
                info["seen"] = "IN USE by another program — close it first: " + busy[0]
                info["busy"] = busy
                found.append(info)
                continue
            try:
                s = serial.Serial(p, 115200, timeout=0.2)
                s.write(b"\r\n"); time.sleep(1.5)
                out = ANSI.sub("", s.read(4096).decode("utf-8", "replace"))
                s.close()
                if UBOOT_PROMPT.search(out):
                    info["seen"] = "U-Boot prompt"
                elif "login:" in out or "activate" in out:
                    info["seen"] = "Linux console (login)"
                elif "#" in out:
                    info["seen"] = "Linux shell"
                elif out.strip():
                    info["seen"] = "output: " + out.strip()[-40:]
            except Exception as e:
                info["seen"] = f"cannot open: {e}"
            found.append(info)
        self.ports = found
        self.stage = "detected"
        self.event(f"detected {len(found)} serial adapter(s)")
        return found

    def start(self, count):
        if self.preflight():
            raise RuntimeError("fix the station problems first")
        if count < 1 or count > len(self.ports):
            raise RuntimeError(f"{count} routers requested but {len(self.ports)} serial adapter(s) detected")
        for i in range(count):
            busy = port_users(self.ports[i]["port"])
            if busy:
                raise RuntimeError(f"Bay {i + 1}: the serial port {os.path.realpath(self.ports[i]['port'])} is in use by "
                                   f"another program ({busy[0]}). Close that console (Ctrl + ] in miniterm), "
                                   "then click Detect again.")
        self.batch_dir = os.path.join(KF, "batches", datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.makedirs(self.batch_dir, exist_ok=True)
        for k, src in self.images.items():                 # publish the images for TFTP
            dst = os.path.join(TFTP_ROOT, os.path.basename(src))
            if not os.path.exists(dst) or os.path.getsize(dst) != os.path.getsize(src):
                shutil.copy2(src, dst)
        self.state["last_batch_size"] = count
        save_state(self.state)
        self.stage = "building"
        self.bays = [Bay(self, i + 1, self.ports[i]["port"]) for i in range(count)]
        self.event(f"batch started: {count} router(s), firmware {self.version}, factory key "
                   f"{os.path.basename(self.factory_key)}")
        for b in self.bays:
            b.start()
        threading.Thread(target=self.supervise, daemon=True).start()

    def append_label(self, bay):
        """Inventory line — no password (owner, 2026-10-25): it is recalculated
        from the factory key whenever needed. key_id says which key made it."""
        with self.lock:
            label_batch.append_inventory(self.labels_csv, bay.mac, bay.unit, "rnode", self.version,
                                         label_batch.key_id(self.factory_key))

    def recover(self, query, reason=""):
        """Lost sticker: new sticker from the factory key + MAC, printed now."""
        if not self.factory_key or not os.path.isfile(self.factory_key):
            raise RuntimeError("No factory key on this station.")
        with self.lock:
            r = label_batch.recover_sticker(self.labels_csv, self.factory_key, query, RECOVERED_DIR,
                                            PRINT_CMD, reason)
        self.event(f"sticker recovered for {r['unit']} ({r['mac']}) — "
                   + ("printed" if r["printed"] else "no printer configured, PNG on screen"))
        r["png"] = os.path.basename(r["png"])
        return r

    # --- sticker step: one bay at a time, after every bay is built ---
    def supervise(self):
        while not all(b.status == "ok" for b in self.bays):
            time.sleep(1)
        self.stage = "labelling"
        self.event("all routers built — sticker step")
        for b in self.bays:
            b.con.sh(f"{LABEL_TOOL} on 3600")
        report = open(os.path.join(self.batch_dir, "report.csv"), "w", newline="")
        rep = csv.writer(report)
        rep.writerow(["bay", "unit", "mac", "result", "time"])
        for b in self.bays:
            b.step = "label"
            png = os.path.join(self.batch_dir, f"bay{b.num}-{b.unit}.png")
            label_batch.render_label(b.unit, b.secret, b.mac, "rnode", png)
            label_batch.print_png(png, PRINT_CMD)
            b.label_png = png
            for o in self.bays:
                o.con.read(0.1); o.con.idents.clear()
            b.con.sh(f"{LABEL_TOOL} led on")
            self.label_bay = b.num
            self.label_msg = (f"Sticker for {b.unit} is on screen. Stick it on the router whose BLUE light is "
                              f"flashing (bay {b.num}), then press THAT router's WPS button.")
            b.say("sticker ready — waiting for the WPS press",
                  "Stick the label on the router with the flashing BLUE light, then press its WPS button.")
            pressed = None
            while pressed is None:
                for o in self.bays:
                    o.con.read(0.1)
                    if o.con.idents:
                        pressed = (o, o.con.idents.pop(0))
                        break
            o, unit = pressed
            if o is b and unit == b.unit:
                b.con.sh(f"{LABEL_TOOL} led off")
                b.finish_step("label")
                b.say(f"✔ sticker confirmed on {b.unit}", "Done — this router can be boxed after the batch.")
                rep.writerow([b.num, b.unit, b.mac, "confirmed", datetime.datetime.now().isoformat()])
                report.flush()
                continue
            o.con.sh(f"{LABEL_TOOL} led on")
            rep.writerow([b.num, b.unit, b.mac, f"MISMATCH pressed {unit} (bay {o.num})", datetime.datetime.now().isoformat()])
            report.close()
            self.stage = "stopped"
            self.label_msg = (f"✘ WRONG ROUTER: the sticker for {b.unit} (bay {b.num}) was confirmed on {unit} "
                              f"(bay {o.num}). Both are flashing. Peel the sticker off and restart the sticker step.")
            self.event(self.label_msg)
            return
        report.close()
        # "Ready to box" means the router is OFF (owner, 2026-10-25): shut each
        # one down cleanly — node stopped, M.2 unmounted — and only then say so.
        # This also ends the station's root shell on the console.
        self.label_bay = None
        self.label_msg = "Stickers confirmed — shutting the routers down cleanly. Leave the power on."
        self.event(self.label_msg)
        for b in self.bays:
            b.con.sh(f"{LABEL_TOOL} off")
            b.step = "done"
            b.say("shutting down cleanly…", "Leave the power ON until this bay says it is off.")
            b.con.read(0.2)
            b.con.write("poweroff\n")
        stuck = []
        for b in self.bays:
            out = b.con.read(SHUTDOWN_TIMEOUT, until=["reboot: Power down"])
            if "reboot: Power down" in out:
                b.finish_step("done")
                b.say("✔ off — ready to box",
                      "Switch off its power and unplug it, then box it with its quick-start card.")
            else:
                b.status = "failed"
                stuck.append(b.num)
                b.say(f"✘ did not shut down within {SHUTDOWN_TIMEOUT // 60} minutes",
                      "Do NOT box it yet. Leave it on and tell the engineer (console log in the batch folder).")
        if stuck:
            self.label_msg = f"✘ Bay(s) {', '.join(map(str, stuck))} did not shut down — do not box them yet."
            self.stage = "stopped"
        else:
            self.label_msg = (f"Batch complete — {len(self.bays)} router(s) built, provisioned, labelled "
                              "and shut down. Switch them off and box them.")
            self.stage = "complete"
        self.event(self.label_msg)

    def snapshot(self):
        return {
            "stage": self.stage, "version": self.version, "last_batch_size": self.state.get("last_batch_size", 1),
            "factory_key": os.path.basename(self.factory_key), "test_key": "TEST" in os.path.basename(self.factory_key),
            "station_ip": STATION_IP, "problems": self.problems, "ports": self.ports,
            "bays": [b.snapshot() for b in self.bays], "label_bay": self.label_bay, "label_msg": self.label_msg,
            "events": self.events[-12:], "batch_dir": self.batch_dir, "printer": bool(PRINT_CMD),
        }


STATION = None


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path in ("/", "/index.html"):
            b = open(os.path.join(HERE, "web", "index.html"), "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        elif u.path == "/api/state":
            self._json(STATION.snapshot())
        elif u.path.startswith("/recovered/"):
            name = os.path.basename(u.path)
            p = os.path.join(RECOVERED_DIR, name)
            if not name.endswith(".png") or not os.path.isfile(p):
                return self._json({"error": "not found"}, 404)
            b = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        elif u.path.startswith("/labels/") and STATION.batch_dir:
            name = os.path.basename(u.path)
            p = os.path.join(STATION.batch_dir, name)
            if not name.endswith(".png") or not os.path.isfile(p):
                return self._json({"error": "not found"}, 404)
            b = open(p, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "image/png")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"{}") if n else {}
        try:
            if u.path == "/api/preflight":
                return self._json({"problems": STATION.preflight()})
            if u.path == "/api/detect":
                STATION.preflight()
                return self._json({"ports": STATION.detect()})
            if u.path == "/api/start":
                STATION.start(int(body.get("count", 1)))
                return self._json({"ok": True})
            if u.path == "/api/recover":
                try:
                    return self._json(STATION.recover(str(body.get("router", "")), str(body.get("reason", ""))))
                except (LookupError, PermissionError) as e:
                    return self._json({"error": str(e)}, 400)
            if u.path == "/api/retry":
                for b in STATION.bays:
                    if b.num == int(body.get("bay", 0)) and b.status == "failed":
                        b.retry_event.set()
                return self._json({"ok": True})
            return self._json({"error": "unknown"}, 404)
        except Exception as e:
            return self._json({"error": str(e)}, 400)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    global STATION
    ap = argparse.ArgumentParser(description="RNode Factory Station")
    ap.add_argument("--listen", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8099)
    a = ap.parse_args()
    STATION = Station()
    STATION.preflight()
    print(f"RNode Factory Station — firmware {STATION.version} — open http://{a.listen}:{a.port}/", flush=True)
    Server((a.listen, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
