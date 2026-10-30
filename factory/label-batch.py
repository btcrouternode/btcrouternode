#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Label a production batch so each sticker lands on the right router.

Owner design, 2026-10-24: after every router in the batch is built and booted
from eMMC, for each bay in turn
  1. print that unit's sticker and flash ITS blue LED (all others dark),
  2. the operator sticks it on the flashing router,
  3. the operator presses THAT router's WPS button — the press is reported on
     the router's own serial line (RNODE-IDENTIFY <unit> <mac>):
       same unit   → confirmed, next sticker
       other unit  → STOP: wrong router, both flash, nothing else proceeds.
The batch is only complete when every bay is confirmed.

Each bay = one USB serial adapter (a fixed hub port: /dev/serial/by-path/…).
The station logs in on each console (root + the unit's label password from
labels.csv, or SERIAL_PASS / the factory password), puts the router in label
mode (files/usr/libexec/knots/factory-label.sh: RAM-only, expires; the WPS
button then only identifies, never reboots or resets) and leaves it at the end.

Usage:
  factory/label-batch.py --bays /dev/ttyUSB0[,/dev/ttyUSB1,…]
      [--labels-csv ~/knots-factory/labels.csv] [--out ~/knots-factory/batches]
      [--print-cmd 'brother_ql … {png}'] [--press-timeout 600] [--no-render]
"""
import argparse, csv, datetime, hashlib, hmac, os, re, shlex, subprocess, sys, tempfile, time

import serial

LABEL_TOOL = "/usr/libexec/knots/factory-label.sh"
FACTORY_PASS = os.environ.get("KNOTS_FACTORY_PASS", "knotsnode21")
IDENT_RX = re.compile(r"RNODE-IDENTIFY (\S+) ([0-9a-f:]*)")


def log(msg):
    print(time.strftime("%H:%M:%S ") + msg, flush=True)


class Bay:
    def __init__(self, num, port):
        self.num, self.port = num, port
        self.ser = serial.Serial(port, 115200, timeout=0.1)
        self.unit = self.mac = self.secret = None
        self.buf = ""
        self.idents = []       # WPS presses seen on this bay's console, in order

    def read(self, t, until=None):
        end, acc = time.time() + t, ""
        while time.time() < end:
            c = self.ser.read(4096)
            if c:
                acc += c.decode("utf-8", "replace")
                if until and any(u in acc for u in until):
                    time.sleep(0.2)
                    acc += self.ser.read(65536).decode("utf-8", "replace")
                    break
        self.buf += acc
        # a press can arrive while a command runs on this bay: never lose it
        self.idents += [m.group(1) for m in IDENT_RX.finditer(acc)]
        return acc

    def write(self, s, chunk=24):
        b = s.encode()
        for i in range(0, len(b), chunk):
            self.ser.write(b[i:i + chunk]); self.ser.flush(); time.sleep(0.02)

    def cmd(self, line, t=8):
        """Run one shell command; output ends at a marker the echo cannot fake."""
        self.read(0.2)
        self.write(line + "; echo __B''AY_DONE__\n")
        out = self.read(t, until=["__BAY_DONE__"])
        return out.split("__BAY_DONE__")[0]

    def login(self, passwords):
        self.write("\n"); out = self.read(2, until=["login:", "# "])
        if "activate" in out and "login:" not in out:
            self.write("\n"); out += self.read(2, until=["login:", "# "])
        if "login:" not in out:
            return True                      # already at a shell
        for pw in passwords:
            self.write("root\n"); self.read(3, until=["assword"])
            self.write(pw + "\n")
            out = self.read(12, until=["# ", "incorrect", "login:"])
            if "incorrect" not in out.lower() and "# " in out:
                return True
            self.read(4, until=["login:"])
        return False

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass


# --- inventory and sticker recovery (owner, 2026-10-25) -----------------------
# labels.csv is an INVENTORY: no passwords. Every sticker password is
# HMAC(factory key, MAC) — recalculated whenever it is needed (sticker step,
# lost-sticker recovery), so the factory key is the only secret to protect.
INVENTORY_FIELDS = ["provisioned_utc", "ethaddr", "unit_name", "wifi_ssid", "product_version", "key_id"]
RECOVERY_FIELDS = ["recovered_utc", "ethaddr", "unit_name", "key_id", "reason", "printed"]
MAC_RX = re.compile(r"^([0-9a-f]{2}:){5}[0-9a-f]{2}$")


def derive_secret(key_file, mac):
    """Same as factory/provision-secret.sh (and the firmware's knots_secret_valid)."""
    key = open(key_file, "rb").read()
    n = int.from_bytes(hmac.new(key, mac.strip().lower().encode(), hashlib.sha256).digest(), "big")
    alphabet = "abcdefghjkmnpqrstuvwxyz23456789"
    chars = []
    for _ in range(12):
        n, r = divmod(n, len(alphabet))
        chars.append(alphabet[r])
    s = "".join(chars)
    return f"{s[0:4]}-{s[4:8]}-{s[8:12]}"


def key_id(key_file):
    """Which factory key made a unit — never the key itself (TEST units marked)."""
    h = hashlib.sha256(open(key_file, "rb").read()).hexdigest()[:8]
    return ("TEST-" if "TEST" in os.path.basename(key_file) else "") + h


def unit_name_for(mac):
    return "rnode-" + mac.replace(":", "").lower()[-4:]


def migrate_inventory(path, key_file=None):
    """Drop the password column from an old labels.csv (once). key_id is filled
    by checking the stored password against this station's key."""
    try:
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
            header = rows and list(rows[0].keys()) or []
    except FileNotFoundError:
        return False
    if "password" not in header:
        return False
    kid = key_id(key_file) if key_file and os.path.isfile(key_file) else None
    out = []
    for r in rows:
        mac = (r.get("ethaddr") or "").lower()
        k = r.get("key_id") or ""
        if not k:
            k = kid if (kid and MAC_RX.match(mac) and r.get("password") == derive_secret(key_file, mac)) else "unknown"
        out.append({f: (k if f == "key_id" else r.get(f, "")) for f in INVENTORY_FIELDS})
    tmp = path + ".tmp"
    with open(tmp, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=INVENTORY_FIELDS, lineterminator="\n")
        w.writeheader()
        w.writerows(out)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return True


def load_labels(path, key_file=None):
    migrate_inventory(path, key_file)
    rows = []
    try:
        with open(path, newline="") as f:
            rows = list(csv.DictReader(f))
    except FileNotFoundError:
        pass
    return rows


def append_inventory(path, mac, unit, ssid, version, kid, when=None):
    migrate_inventory(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    new = not os.path.exists(path) or os.path.getsize(path) == 0
    with open(path, "a", newline="") as f:
        os.chmod(path, 0o600)
        w = csv.writer(f, lineterminator="\n")
        if new:
            w.writerow(INVENTORY_FIELDS)
        w.writerow([when or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                    mac, unit, ssid, version, kid])


def find_unit(rows, query):
    """A router name (rnode-xxxx) or a MAC; the latest inventory line wins."""
    q = (query or "").strip().lower()
    if MAC_RX.match(q.replace("-", ":")):
        q = q.replace("-", ":")
    elif re.fullmatch(r"[0-9a-f]{4}", q):          # just the 4 characters from the name
        q = "rnode-" + q
    for r in reversed(rows):
        if q in ((r.get("ethaddr") or "").lower(), (r.get("unit_name") or "").lower()):
            return r
    return None


def print_png(png, print_cmd):
    """Print one sticker; no printer configured = PNG only (dry run)."""
    if not print_cmd:
        return False
    subprocess.run(print_cmd.replace("{png}", shlex.quote(png)), shell=True, check=True)
    return True


def recover_sticker(inventory, key_file, query, outdir, print_cmd=None, reason=""):
    """Lost sticker: recalculate the password from the factory key and the MAC,
    render a new sticker and print it now. Logged without the password."""
    r = find_unit(load_labels(inventory, key_file), query)
    if not r:
        raise LookupError(f"{query!r} is not in the inventory ({inventory}) — check the router name or MAC")
    mac, unit = r["ethaddr"].lower(), r.get("unit_name") or unit_name_for(r["ethaddr"])
    mine = key_id(key_file)
    if r.get("key_id") != mine:
        raise PermissionError(f"{unit} was made with factory key {r.get('key_id') or 'unknown'}; "
                              f"this station has {mine} — its password cannot be recovered here")
    os.makedirs(outdir, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    png = os.path.join(outdir, f"{stamp}-{unit}.png")
    render_label(unit, derive_secret(key_file, mac), mac, r.get("wifi_ssid") or "rnode", png)
    printed = print_png(png, print_cmd)
    log_path = os.path.join(os.path.dirname(inventory) or ".", "recoveries.csv")
    new = not os.path.exists(log_path)
    with open(log_path, "a", newline="") as f:
        os.chmod(log_path, 0o600)
        w = csv.writer(f, lineterminator="\n")
        if new:
            w.writerow(RECOVERY_FIELDS)
        w.writerow([stamp, mac, unit, mine, (reason or "").replace("\n", " ")[:200], "yes" if printed else "no"])
    return {"unit": unit, "mac": mac, "png": png, "printed": printed}


def render_label(unit, secret, mac, ssid, path, setup_url="http://192.168.1.254/"):
    """Router sticker on 29 mm film tape at 300 dpi (Brother DK-22211), ~29 × 100 mm.
    Text only (owner decision 2026-10-25): Setup is done from a laptop or computer —
    it installs the secure-connection certificate first, which phones and tablets
    cannot do easily — and laptops do not scan QR codes. The Wi-Fi password is only
    valid until Setup (Setup requires a new one), so there is no Wi-Fi QR either.
    The laptop's "sign in to network" window opens Setup by itself; the unit's
    own name (rnode-xxxx.local — Windows, macOS and Linux all resolve .local) is
    for a cable or when it does not, with the IP address as the fallback."""
    from PIL import Image, ImageDraw, ImageFont
    W, H = 1180, 306

    def font(name, size):
        p = f"/usr/share/fonts/truetype/dejavu/{name}.ttf"
        return ImageFont.truetype(p, size) if os.path.exists(p) else ImageFont.load_default()

    img = Image.new("1", (W, H), 1)
    dr = ImageDraw.Draw(img)
    head, bold, reg = font("DejaVuSans-Bold", 34), font("DejaVuSans-Bold", 28), font("DejaVuSans", 23)
    big = font("DejaVuSansMono-Bold", 44)
    small, mono = font("DejaVuSans", 19), font("DejaVuSansMono", 18)

    dr.text((14, 6), "Set up with a laptop or computer", font=head, fill=0)
    dr.line((14, 52, W - 14, 52), fill=0, width=3)

    def num(x, y, n):
        dr.ellipse((x, y, x + 50, y + 50), fill=0)
        tw = dr.textlength(n, font=bold)
        dr.text((x + (50 - tw) / 2, y + 7), n, font=bold, fill=1)

    x1, x2, y = 14, 610, 64
    num(x1, y, "1")
    dr.text((x1 + 66, y + 4), "Join Wi-Fi", font=bold, fill=0)
    dr.text((x1 + 66 + dr.textlength("Join Wi-Fi ", font=bold), y + 4), ssid, font=font("DejaVuSansMono-Bold", 30), fill=0)
    dr.text((x1 + 66, y + 60), "Password", font=reg, fill=0)
    dr.text((x1 + 66, y + 88), secret, font=big, fill=0)
    dr.text((x1 + 66, y + 146), "or plug a cable into a LAN port", font=reg, fill=0)

    num(x2, y, "2")
    dr.text((x2 + 66, y + 4), "Setup opens by itself", font=bold, fill=0)
    dr.text((x2 + 66, y + 60), "If it does not, go to", font=reg, fill=0)
    url = f"http://{unit}.local"
    uf = next(f for f in (font("DejaVuSans-Bold", z) for z in (38, 34, 30, 26, 22)) if dr.textlength(url, font=f) <= W - x2 - 80)
    dr.text((x2 + 66, y + 92), url, font=uf, fill=0)
    dr.text((x2 + 66, y + 146), "or " + setup_url.rstrip("/"), font=reg, fill=0)

    dr.line((14, 252, W - 14, 252), fill=0, width=2)
    dr.text((14, 264), "Router login: root / same password", font=small, fill=0)
    dr.text((W - 14 - dr.textlength(f"MAC {mac}", font=mono), 266), f"MAC {mac}", font=mono, fill=0)
    img.save(path, dpi=(300, 300))
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bays", required=True, help="comma-separated serial ports, bay 1 first")
    kf = os.path.expanduser("~/knots-factory")
    ap.add_argument("--labels-csv", default=os.environ.get("KNOTS_LABELS_CSV", f"{kf}/labels.csv"))
    ap.add_argument("--out", default=f"{kf}/batches")
    ap.add_argument("--print-cmd", default=os.environ.get("KNOTS_LABEL_PRINT_CMD", ""),
                    help="command to print one label; {png} is replaced by the file")
    ap.add_argument("--press-timeout", type=int, default=600)
    ap.add_argument("--no-render", action="store_true", help="skip PNG rendering (tests)")
    a = ap.parse_args()

    key_file = os.environ.get("KNOTS_FACTORY_KEY_FILE", "")
    if not key_file or not os.path.isfile(key_file):
        raise SystemExit("KNOTS_FACTORY_KEY_FILE not set — passwords are recalculated from the factory key")
    labels = load_labels(a.labels_csv, key_file)
    by_mac = {}
    for r in labels:                                   # latest provisioning wins
        by_mac[(r.get("ethaddr") or "").lower()] = r
    passwords = [p for p in os.environ.get("SERIAL_PASS", "").split(",") if p]
    passwords += [derive_secret(key_file, r["ethaddr"].lower()) for r in reversed(labels[-10:])
                  if MAC_RX.match((r.get("ethaddr") or "").lower())]
    passwords.append(FACTORY_PASS)

    batch = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir = os.path.join(a.out, batch)
    os.makedirs(outdir, exist_ok=True)
    report = open(os.path.join(outdir, "report.csv"), "w", newline="")
    rep = csv.writer(report)
    rep.writerow(["bay", "port", "unit", "mac", "result", "time"])

    bays = [Bay(i + 1, p) for i, p in enumerate(a.bays.split(","))]
    rc = 0
    try:
        # --- connect, identify, label mode on --------------------------------
        for b in bays:
            if not b.login(passwords):
                raise SystemExit(f"bay {b.num} ({b.port}): console login failed — set SERIAL_PASS")
            out = b.cmd(f"{LABEL_TOOL} on 3600")
            m = re.search(r"label-mode on (\S+) ([0-9a-f:]+)", out)
            if not m:
                raise SystemExit(f"bay {b.num}: label mode not available (firmware older than label mode?)\n{out[-300:]}")
            b.unit, b.mac = m.group(1), m.group(2)
            row = by_mac.get(b.mac)
            if not row:
                raise SystemExit(f"bay {b.num}: {b.unit} ({b.mac}) is not in {a.labels_csv} — provision it first")
            b.secret, b.ssid = derive_secret(key_file, b.mac), row.get("wifi_ssid") or "rnode"
            log(f"bay {b.num}: {b.unit} {b.mac} — label mode on")
        units = [b.unit for b in bays]
        if len(set(units)) != len(units):
            raise SystemExit(f"two bays report the same unit {units} — check the serial cables")

        # --- one sticker at a time --------------------------------------------
        for b in bays:
            png = os.path.join(outdir, f"bay{b.num}-{b.unit}.png")
            if not a.no_render:
                render_label(b.unit, b.secret, b.mac, b.ssid, png)
                if a.print_cmd:
                    subprocess.run(a.print_cmd.replace("{png}", shlex.quote(png)), shell=True, check=True)
            for o in bays:
                o.read(0.1); o.idents.clear()        # presses before the light is on do not count
            b.cmd(f"{LABEL_TOOL} led on")
            log(f"bay {b.num}: sticker for {b.unit} {'printed' if a.print_cmd else 'ready: ' + png}")
            log(f"   → stick it on the router with the FLASHING BLUE light, then press THAT router's WPS button")
            pressed, t_end = None, time.time() + a.press_timeout
            while pressed is None and time.time() < t_end:
                for o in bays:
                    o.read(0.1)
                    if o.idents:
                        pressed = (o, o.idents.pop(0))
                        break
            if pressed is None:
                raise SystemExit(f"bay {b.num}: no WPS press within {a.press_timeout}s")
            o, unit = pressed
            if o is b and unit == b.unit:
                b.cmd(f"{LABEL_TOOL} led off")
                log(f"bay {b.num}: ✔ sticker confirmed on {b.unit}")
                rep.writerow([b.num, b.port, b.unit, b.mac, "confirmed", datetime.datetime.now().isoformat()])
                report.flush()
                continue
            o.cmd(f"{LABEL_TOOL} led on")
            log(f"bay {b.num}: ✘ WRONG ROUTER — the sticker for {b.unit} was confirmed on {unit} (bay {o.num}).")
            log("   Both routers are flashing. Peel the sticker off, put it on the right router, then re-run.")
            rep.writerow([b.num, b.port, b.unit, b.mac, f"MISMATCH pressed {unit} (bay {o.num})",
                          datetime.datetime.now().isoformat()])
            rc = 1
            return rc
        log(f"batch complete: {len(bays)} stickers confirmed — report {outdir}/report.csv")
    finally:
        if rc == 0:
            for b in bays:
                if b.unit:
                    b.cmd(f"{LABEL_TOOL} off")
                b.write("exit\n")
        report.close()
        for b in bays:
            b.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
