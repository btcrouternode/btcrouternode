#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Productionise a unit: move the Phase 2 system from microSD to eMMC (DOC3a / R5a).
#
# Orchestrates the ONLY supported path (SD and eMMC share one MMC controller —
# eMMC is electrically hidden while the SD is inserted, and the SD U-Boot has no
# eMMC-install entry):   SD → SPI-NAND (bridge) → eMMC.
# (Stock menu entries: SD #7 "Install … to NAND", NAND #9 "Install … to eMMC".)
#
# Exactly TWO physical steps. Before each, the script reboots into Linux and
# powers the router off via ssh (U-Boot has no `poweroff` on BPI-R4); it then
# watches the USB serial for the next boot — no key presses needed:
#   STEP 1: DIP SW3 A=0 B=1 (SPI-NAND) + REMOVE microSD + power on
#   STEP 2: DIP SW3 A=1 B=0 (eMMC)     + leave SD out   + power on
#
# Phases:
#   1  SD boot → U-Boot menu "Install … to NAND" → reboot → poweroff
#   2  NAND U-Boot → guards (eMMC visible = $EMMC_NAME; F28: NAND blob is the
#      7391 GPT) → run emmc_init → verify GPT partitions → reboot → poweroff
#   3  Watch production boot → ssh verify (root=/dev/fit0, eMMC, p5, fitrw, version)
#
# Never touches /dev/nvme0n1 (chain data, NF8).
#
#   4  Provision the per-device factory secret (P1): HMAC(factory key, ethaddr)
#      → U-Boot env knots_secret, applied to root + default Wi-Fi; prints the
#      label (factory/provision-secret.sh). Needs KNOTS_FACTORY_KEY_FILE.
#
# Lab one-off: --clear-old-secret  (unit booting from its OLD eMMC, DIP A=1 B=0):
#   catch U-Boot on the console, delete a previous provisioning (knots_secret)
#   from the eMMC U-Boot env, saveenv — so a re-used board is provisioned like
#   a new one. The MAC (ethaddr) is kept. Then run the normal production.
# Read-only:   --uboot-info   (any boot medium): catch U-Boot, print its env,
#   eMMC info and partition table (TFTP planning), write nothing.
# Usage: factory/install-emmc-from-sd.sh [--from-phase N] [--to-phase N] [-y|--yes]
#        (--to-phase 1 = SD → SPI-NAND only; used by flash-nand-from-sd-menu7.sh)
# Env:   PORT=/dev/ttyUSB0 BAUD=115200 ROUTER_SSH=root@192.168.1.254
#        EMMC_NAME=8GTF4R WAIT_SEC=240 SSH_WAIT_SEC=420
#        KNOTS_STATION_KEY=~/knots-factory/station_ed25519  (factory/station-setup.sh)
#        KNOTS_FACTORY_PASS=knotsnode21   (unit's pre-provisioning root password)
# Requires: python3 + pyserial, USB-TTL on the 3-pin UART (115200 8N1).
# Station access: a fresh unit only accepts passwords and its host key changes
# with every boot medium (SD / NAND / eMMC). The script logs in on the serial
# console once per boot (root + factory password; 88-knots-ttylogin), installs
# this station's ssh key (comment rnode-factory-station), runs everything else
# over ssh, and REMOVES the key again at the end of phase 4 — shipped units
# never trust the factory station. Host keys are not recorded (direct cable,
# one unit at a time).
# Resume after Ctrl-C/failure with --from-phase N.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PORT="${PORT:-/dev/ttyUSB0}"
BAUD="${BAUD:-115200}"
ROUTER_SSH="${ROUTER_SSH:-root@192.168.1.254}"
EMMC_NAME="${EMMC_NAME:-8GTF4R}"
export WAIT_SEC="${WAIT_SEC:-240}"
export SSH_WAIT_SEC="${SSH_WAIT_SEC:-420}"
export KNOTS_FACTORY_KEY_FILE="${KNOTS_FACTORY_KEY_FILE:-}"
export PROVISION="$ROOT/factory/provision-secret.sh"

START_PHASE=1
END_PHASE=4
ASSUME_YES=0
CLEAR_SECRET=0
while [ $# -gt 0 ]; do
	case "$1" in
		--from-phase) START_PHASE="${2:?}"; shift 2 ;;
		--to-phase)   END_PHASE="${2:?}"; shift 2 ;;
		-y|--yes)     ASSUME_YES=1; shift ;;
		--clear-old-secret) CLEAR_SECRET=1; shift ;;
		--uboot-info) CLEAR_SECRET=2; shift ;;
		-h|--help)    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d'; exit 0 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
done
case "$START_PHASE" in 1|2|3|4) ;; *) echo "--from-phase must be 1|2|3|4" >&2; exit 2 ;; esac
case "$END_PHASE" in 1|2|3|4) ;; *) echo "--to-phase must be 1|2|3|4" >&2; exit 2 ;; esac
[ "$END_PHASE" -ge "$START_PHASE" ] || { echo "--to-phase must be >= --from-phase" >&2; exit 2; }

# Expected product version from build/version.env (F28 guard: must be a 7391 build).
OV="$(sed -n 's/^OPENWRT_VER[[:space:]]*:=[[:space:]]*//p' "$ROOT/build/version.env" | tr -d '[:space:]')"
KV="$(sed -n 's/^KNOTS_VER[[:space:]]*:=[[:space:]]*//p'    "$ROOT/build/version.env" | tr -d '[:space:]')"
BN="$(sed -n 's/^BUILD_NUM[[:space:]]*:=[[:space:]]*//p'   "$ROOT/build/version.env" | tr -d '[:space:]')"
EXPECTED_VER="${OV:+${OV}.${KV}.${BN}}"

python3 -c 'import serial' 2>/dev/null || {
	echo "pyserial required (e.g. pip install pyserial)" >&2; exit 1; }
[ -e "$PORT" ] || { echo "serial port $PORT not found (override PORT=)" >&2; exit 1; }

exec python3 - "$PORT" "$BAUD" "$ROUTER_SSH" "$EMMC_NAME" "$EXPECTED_VER" \
	"$START_PHASE" "$ASSUME_YES" "$END_PHASE" "$CLEAR_SECRET" << 'PY'
import os, re, subprocess, sys, time

PORT, BAUD = sys.argv[1], int(sys.argv[2])
ROUTER_SSH, EMMC_NAME, EXPECTED_VER = sys.argv[3], sys.argv[4], sys.argv[5]
START_PHASE, ASSUME_YES = int(sys.argv[6]), sys.argv[7] == '1'
END_PHASE = int(sys.argv[8]) if len(sys.argv) > 8 else 4
CLEAR_SECRET = len(sys.argv) > 9 and sys.argv[9] == '1'
UBOOT_INFO = len(sys.argv) > 9 and sys.argv[9] == '2'
WAIT_SEC = int(os.environ.get('WAIT_SEC', '240'))
SSH_WAIT_SEC = int(os.environ.get('SSH_WAIT_SEC', '420'))
STATION_KEY = os.path.expanduser(os.environ.get('KNOTS_STATION_KEY', '~/knots-factory/station_ed25519'))
FACTORY_PASS = os.environ.get('KNOTS_FACTORY_PASS', 'knotsnode21')
STATION_TAG = 'rnode-factory-station'
# Direct cable to one unit at a time; every boot medium has new host keys.
SSH_BASE = ['-o', 'BatchMode=yes', '-o', 'UserKnownHostsFile=/dev/null',
            '-o', 'StrictHostKeyChecking=no', '-o', 'LogLevel=ERROR']
if os.path.exists(STATION_KEY):
    SSH_BASE += ['-i', STATION_KEY, '-o', 'IdentitiesOnly=yes']

import serial

try:
    TTY = open('/dev/tty')
except OSError:
    TTY = None

def ask(question, default=False):
    # -y only answers the routine prompts (default=True). Safety guards
    # (default=False) still refuse: an unverified GPT must never be written
    # unattended (review T2).
    if ASSUME_YES:
        if not default:
            print(f'{question} -- safety prompt; -y does not override, answering NO')
        return default
    if TTY is None:
        print(f'{question} -- non-interactive, assuming NO')
        return False
    print(f'{question} [{"Y/n" if default else "y/N"}] ', end='', flush=True)
    ans = TTY.readline().strip().lower()
    return ans in ('y', 'yes') if ans else default

CURRENT_PHASE = [START_PHASE]

def die(msg, code=1):
    print(f'\nABORT: {msg}')
    sys.exit(code)

def step(msg):
    print(f'\n=== {msg} ===')

# ---------- serial ----------
ANSI_RX = re.compile(r'\x1b\[[0-9;?]*[ -/]*[@-~]')

def strip_ansi(s):
    return ANSI_RX.sub('', s)

def send(ser, s, delay=0.4):
    ser.write(s.encode('latin-1') if isinstance(s, str) else s)
    ser.flush()
    time.sleep(delay)

def read_for(ser, t):
    end = time.time() + t
    buf = b''
    while time.time() < end:
        n = ser.in_waiting
        if n:
            buf += ser.read(n)
        time.sleep(0.05)
    return buf.decode('utf-8', errors='replace')

def wait_for(ser, patterns, timeout, echo=True):
    """Watch serial until one of the regex patterns matches. Returns (idx|-1, text)."""
    end = time.time() + timeout
    acc = ''
    pats = [re.compile(p, re.I) for p in patterns]
    while time.time() < end:
        chunk = read_for(ser, 1.0)
        if not chunk:
            continue
        if echo:
            print(chunk, end='', flush=True)
        acc += chunk
        for i, rx in enumerate(pats):
            if rx.search(acc[-4000:]):
                return i, acc
    return -1, acc

def wait_prompt(ser, timeout=60, idle=8):
    """Read until the U-Boot shell prompt returns (or output goes idle)."""
    end = time.time() + timeout
    acc, last = '', time.time()
    while time.time() < end:
        chunk = read_for(ser, 1.0)
        if chunk:
            print(chunk, end='', flush=True)
            acc += chunk
            last = time.time()
            if re.search(r'(MT7988>|=>)\s*$', acc[-200:]):
                break
        elif acc and time.time() - last > idle:
            break
    return acc

def shell_cmd(ser, cmd, timeout=60):
    send(ser, cmd + '\n', 0.3)
    return wait_prompt(ser, timeout)

# ---------- U-Boot menu ----------
def freeze_menu(ser, timeout):
    """Catch autoboot and stop at the boot menu.
    Returns ('menu'|'shell'|'linux'|None, text). 'linux' = boot went straight to
    Linux (fresh env, bootdelay=0 — no countdown on first boot of a medium)."""
    print(f'\n[watching {PORT} up to {timeout}s for the U-Boot autoboot prompt]')
    idx, acc = wait_for(ser, ['Hit any key', 'stop autoboot', r'MT7988>\s*$',
                              'Linux version', 'Please press Enter'], timeout)
    if idx == 2:
        return 'shell', acc
    if idx in (3, 4):
        return 'linux', acc
    if idx < 0:
        return None, acc
    send(ser, ' ', 0.8)  # any key freezes the menu (SPACE cannot select an entry)
    menu = read_for(ser, 2.0)
    print(menu)
    return 'menu', acc + menu

def menu_entry(text, label_rx, fallback):
    rx = re.compile(label_rx, re.I)
    for line in strip_ansi(text).splitlines():
        m = re.match(r'\s*(\d+)\s*[.:)]\s+(.+?)\s*$', line)
        if m and rx.search(m.group(2)):
            return m.group(1), m.group(2)
    return fallback, None

def enter_shell(ser, menu_text):
    """Drop from the boot menu to the MT7988> prompt (menu item 0 = Exit)."""
    if not re.search(r'(MT7988>|=>)\s*$', strip_ansi(menu_text)[-200:]):
        num, label = menu_entry(menu_text, r'shell|console|exit', '0')
        print(f'[leaving menu via item {num}' + (f': "{label}"' if label else ' (fallback 0=Exit)') + ']')
        send(ser, num + '\n', 0.5)
        wait_prompt(ser, 15)

# ---------- ssh ----------
def ssh_run(cmd, timeout=12):
    try:
        r = subprocess.run(['ssh'] + SSH_BASE + ['-o', 'ConnectTimeout=4', ROUTER_SSH, cmd],
                           capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip()
    except Exception as e:
        return 255, str(e)

def send_slow(ser, s, chunk=24, gap=0.03):
    """Type a long line in small chunks — the console drops characters when a
    long line arrives at full speed (seen on the bench, 2026-10-22)."""
    b = s.encode('latin-1')
    for i in range(0, len(b), chunk):
        ser.write(b[i:i + chunk]); ser.flush(); time.sleep(gap)

def console_install_station_key(ser):
    """Log in on the serial console (root + factory password; images before .99
    open a shell directly) and add this station's public key to dropbear."""
    pub_path = STATION_KEY + '.pub'
    if not os.path.exists(pub_path):
        print(f'NOTE: no station key {pub_path} (run factory/station-setup.sh) — ssh will need manual help.')
        return False
    pub = open(pub_path).read().strip()
    if STATION_TAG not in pub or "'" in pub:
        print(f'NOTE: {pub_path} is not a station key (comment {STATION_TAG}).')
        return False
    send(ser, '\n', 1.0)
    out = read_for(ser, 2)
    if 'activate' in out and 'login:' not in out:
        send(ser, '\n', 1.0); out += read_for(ser, 2)
    if 'login:' in out:
        send(ser, 'root\n', 1.0); read_for(ser, 2)
        send(ser, FACTORY_PASS + '\n', 2.0)
        out = read_for(ser, 4)
        if 'incorrect' in out.lower():
            print('NOTE: console login refused — this unit no longer has the factory password '
                  '(already provisioned / set up?). Set KNOTS_FACTORY_PASS or add the key by hand.')
            return False
    send_slow(ser, f"mkdir -p /etc/dropbear; grep -qF '{pub}' /etc/dropbear/authorized_keys 2>/dev/null "
                   f"|| echo '{pub}' >>/etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys; "
                   "echo STATION''_KEY_OK\n")
    out = read_for(ser, 3)
    send(ser, 'exit\n', 0.5)
    return 'STATION_KEY_OK' in out

def ensure_ssh(ser, attempts=3):
    """ssh to the unit with the station key; install the key via the console if needed."""
    for _ in range(attempts):
        rc, _ = ssh_run('true', 8)
        if rc == 0:
            return True
        if console_install_station_key(ser):
            time.sleep(1)
            rc, _ = ssh_run('true', 8)
            if rc == 0:
                print('[station key installed via the serial console]')
                return True
        time.sleep(5)
    return False

def remove_station_key():
    rc, _ = ssh_run(f"sed -i '/{STATION_TAG}/d' /etc/dropbear/authorized_keys 2>/dev/null; "
                    f"! grep -q '{STATION_TAG}' /etc/dropbear/authorized_keys 2>/dev/null", 10)
    print('[station ssh key removed from the unit]' if rc == 0 else
          'WARNING: could not confirm the station ssh key was removed — check /etc/dropbear/authorized_keys')
    return rc == 0

def reboot_and_poweroff(ser, desc):
    """U-Boot has no poweroff on BPI-R4 (ATF system_off is an unhandled stub), so
    reboot into Linux and power off from there. Falls back to manual power-off."""
    send(ser, 'reset\n', 0.5)  # watchdog soft reset — works on MT7988
    print(f'Rebooting into {desc} Linux for a clean script-driven shutdown...')
    wait_for(ser, ['Please press Enter to activate', 'login:'], WAIT_SEC)
    if not ensure_ssh(ser):
        print('WARNING: router not reachable via ssh — power it OFF manually (pull PSU).')
        return False
    print('Router is up — halting via ssh (BPI-R4 does not cut its own power)...')
    deadline = time.time() + SSH_WAIT_SEC
    while time.time() < deadline:
        rc, _ = ssh_run('poweroff', 10)
        if rc == 0:
            time.sleep(8)
            print('Router halted — LEDs may stay on; pull the PSU for a full power cut.')
            return True
        time.sleep(5)
    print('WARNING: poweroff via ssh failed — power it OFF manually (pull PSU).')
    return False

PHYS1 = '''
########################################################
#  PHYSICAL STEP 1 of 2 (only two in the whole process)
#  The router should now be powered OFF (if not: pull PSU).
#    1. Set DIP SW3:  A=0, B=1   -> SPI-NAND
#       (use the 0/1 printed on the switch itself)
#    2. REMOVE the microSD card
#       (eMMC stays electrically hidden while it is in)
#    3. Power on.
#  Watching the serial line for the NAND U-Boot -
#  no key presses needed.
########################################################'''

PHYS2 = '''
########################################################
#  PHYSICAL STEP 2 of 2 (last one)
#  The router should now be powered OFF (if not: pull PSU).
#    1. Set DIP SW3:  A=1, B=0   -> eMMC
#    2. Leave the microSD OUT.
#    3. Power on.
#  Watching the serial line for the production boot.
########################################################'''

# ---------- phases ----------
def phase1(ser):
    step('PHASE 1: install SD -> SPI-NAND (U-Boot menu)')
    ensure_ssh(ser, attempts=1)
    rc, ver = ssh_run('cat /etc/knots/product_version 2>/dev/null')
    ssh_up = rc == 0
    if ssh_up:
        _, mmc = ssh_run('cat /sys/class/block/mmcblk0/device/name 2>/dev/null')
        print(f'Router reachable at {ROUTER_SSH}: product_version={ver!r} mmc={mmc!r}')
        if mmc.strip() == EMMC_NAME:
            die(f'router is already running from eMMC ({EMMC_NAME}). Boot from SD first.')
        if EXPECTED_VER and ver.strip() != EXPECTED_VER:
            print(f'WARNING: SD runs {ver!r}, tree expects {EXPECTED_VER!r}.')
            print('A stale (pre-7391) SD embeds the broken 7408 eMMC GPT (F28).')
            ask('Continue anyway?', default=False) or die('stale SD image', 1)
        # The SD's embedded emmc_install blob (GPT @ 56MiB + 0x220) predates any
        # sysupgrade — check it directly; a pre-7391 flash stays broken (F28).
        _, blob = ssh_run("dd if=/dev/mmcblk0 bs=1 skip=58720800 count=4 2>/dev/null | "
                          "hexdump -v -e '4/1 \"%02x\"'")
        blob = blob.strip().lower()
        if blob == '20f8e800':
            print('[guard OK] SD-embedded emmc_install blob carries the 7391 GPT')
        elif blob == '20f8e900':
            die('SD was originally flashed with a pre-7391 image (broken 7408 GPT, F28) — '
                'sysupgrade does NOT refresh the embedded eMMC payload. Re-flash the SD '
                '(make flash-sd) or patch the blob per factory/README.md.', 1)
        else:
            # Empty = dd/hexdump failed: unverified, not OK (review T18).
            ask(f'WARNING: unexpected SD blob GPT bytes {blob or "(unreadable)"!r} '
                '(want 20f8e800). Continue?',
                default=False) or die('unverified SD blob', 1)
    else:
        print(f'NOTE: {ROUTER_SSH} not reachable via ssh (BatchMode).')
        print('Preflight version check skipped; power-cycle and power-off are manual.')
    ask('Start phase 1 (reboot router, install to NAND)?', default=True) or die('cancelled', 1)

    if ssh_up:
        print('Rebooting via ssh — if nothing happens in 30s, power-cycle the router yourself.')
        ssh_run('reboot', timeout=8)
    else:
        print('Power-cycle the router now (DIP must be SD: A=1 B=1, SD inserted).')

    state, text = freeze_menu(ser, WAIT_SEC)
    if state is None:
        die('no U-Boot menu seen. SD inserted? DIP A=1 B=1? serial wired? '
            'Then re-run: --from-phase 1', 2)
    if state == 'linux':
        die('boot went straight to Linux — power-cycle and re-run --from-phase 1 '
            'to catch the menu', 2)
    if state == 'shell':
        send(ser, 'bootmenu\n', 0.5)
        text += read_for(ser, 2.5)
        print(text[-2000:])

    num, label = menu_entry(text, r'install.*\bnand\b', '7')
    print(f'NAND install = menu item {num}' + (f': "{label}"' if label else ' (FALLBACK — menu not parsed, see above)'))
    ask(f'Run menu item {num} now?', default=True) or die('cancelled', 1)
    send(ser, num + '\n')
    idx, acc = wait_for(ser, [r'not detected', 'Press ENTER to return',
                              'Installation abort', r'\bfail', r'\berror'], 600)
    if idx != 1 or re.search(r'not detected', acc, re.I):
        die('NAND install did not report success — check the log above.', 1)
    send(ser, '\n', 0.8)
    read_for(ser, 1.5)

    enter_shell(ser, text)
    reboot_and_poweroff(ser, 'SD')
    print(PHYS1)

def phase2(ser):
    step('PHASE 2: install SPI-NAND -> eMMC (run emmc_init)')
    state, text = None, ''
    for _ in range(3):
        state, text = freeze_menu(ser, WAIT_SEC)
        if state in ('menu', 'shell'):
            break
        if state == 'linux':
            die('NAND booted straight to Linux (fresh env, bootdelay=0). Either '
                'power-cycle and retry (--from-phase 2), or from NAND Linux run: '
                'fw_setenv bootcmd "run emmc_init ; env default bootcmd ; saveenv ; '
                'saveenv ; reset" && reboot — then power off, DIP eMMC (A=1 B=0), '
                'and resume with --from-phase 3', 2)
        ask('No NAND U-Boot seen. Power-cycle (DIP A=0 B=1, SD out) and retry?', default=True) \
            or die('no NAND U-Boot', 2)
    else:
        die('no NAND U-Boot after 3 attempts', 2)

    medium = strip_ansi(text)
    if '[SD card]' in medium:
        die('this is the SD U-Boot — SD still inserted or DIP wrong. Power off, '
            'remove SD, DIP A=0 B=1, power on; resume: --from-phase 2', 1)
    if '[SPI-NAND]' in medium:
        print('[guard OK] boot menu is the SPI-NAND U-Boot')

    enter_shell(ser, text)

    # Guard 1: eMMC must be the visible MMC device (SD still in = classic failure).
    out = shell_cmd(ser, 'mmc dev 0', 20) + shell_cmd(ser, 'mmcinfo', 20)
    if EMMC_NAME not in out:
        die(f'eMMC ({EMMC_NAME}) not visible on mmc0 — SD still inserted or wrong DIP. '
            'Power off, remove SD, DIP A=0 B=1, power on; resume: --from-phase 2', 1)
    print(f'[guard OK] mmc0 is the eMMC ({EMMC_NAME})')

    # Guard 2 (F28): NAND emmc_install blob must carry the 7391 GPT
    # (backup LBA 0x00e8f820), not the broken 7408 one (0x00e98020).
    shell_cmd(ser, 'ubi part ubi', 20)
    out = shell_cmd(ser, 'ubi read 0x50000000 emmc_install 0x800000', 30)
    if re.search(r'not found|\berror\b|\bfail', out, re.I):
        ask('WARNING: could not read NAND emmc_install volume. Continue without F28 guard?',
            default=False) or die('emmc_install unreadable', 1)
    else:
        out = shell_cmd(ser, 'md.l 0x50500220 1', 20)
        m = re.search(r'50500220:\s*([0-9a-fA-F]{8})', out)
        val = m.group(1).lower() if m else ''
        if val == '00e8f820':
            print('[guard OK] NAND emmc_install carries the 7391 GPT (F28-fixed)')
        elif val == '00e98020':
            die('NAND emmc_install is the BROKEN 7408 GPT (F28). Re-flash the SD with the '
                'current image and redo phase 1 (or patch per factory/README.md).', 1)
        else:
            ask(f'WARNING: unexpected GPT backup-LBA word {val!r} (want 00e8f820). Continue?',
                default=False) or die('unverified GPT blob', 1)

    ask('Run emmc_init (writes BL2+FIP+GPT+recovery+production to eMMC)?', default=True) \
        or die('cancelled', 1)
    send(ser, 'run emmc_init\n', 0.5)
    out = wait_prompt(ser, 600, idle=20)
    if re.search(r'not detected|exceeds max|gpt verify.*(error|fail)|crc32 error|'
                 r'Bad hash in FIT|\bFAIL', out, re.I):
        die('emmc_init reported errors — see docs/FIX_F28_EMMC_GPT_OVERFLOW.md '
            'and factory/restore-emmc-from-nand.md', 1)

    out = shell_cmd(ser, 'part list mmc 0', 30)
    if not ('production' in out and 'recovery' in out):
        die('eMMC GPT written but production/recovery partitions missing — F28-class '
            'failure, see docs/FIX_F28_EMMC_GPT_OVERFLOW.md', 1)
    print('[guard OK] eMMC has production + recovery partitions')

    reboot_and_poweroff(ser, 'NAND')
    print(PHYS2)

def phase3(ser):
    step('PHASE 3: verify production boot from eMMC')
    print('First eMMC boot auto-initialises its U-Boot env (may reset itself once) —')
    print('watching passively (sending nothing — autoboot must run)...')
    idx, _ = wait_for(ser, ['Please press Enter to activate', 'login:',
                            'TFTP', 'Failed to initialize GPT'], 300)
    if idx in (2, 3):
        print('WARNING: boot fell back to TFTP / GPT panic — production may be empty (F28).')

    print(f'\nWaiting up to {SSH_WAIT_SEC}s for ssh ({ROUTER_SSH})...')
    deadline = time.time() + SSH_WAIT_SEC
    while time.time() < deadline:
        if ensure_ssh(ser, attempts=1):
            break
        time.sleep(5)
    else:
        print('ssh never came up. Verify manually on the console:')
        print('  cat /proc/cmdline   (root=/dev/fit0)   |   lsblk   (~7.3G mmcblk0 = eMMC)')
        sys.exit(2)

    fails = 0
    def check(name, ok, detail=''):
        nonlocal fails
        fails += 0 if ok else 1
        print(f'{"PASS" if ok else "FAIL"}  {name}' + (f'  ({detail})' if detail else ''))

    rc, out = ssh_run('cat /proc/cmdline')
    check('root=/dev/fit0', rc == 0 and 'root=/dev/fit0' in out)
    rc, out = ssh_run('cat /sys/class/block/mmcblk0/device/name 2>/dev/null')
    check(f'mmcblk0 is eMMC ({EMMC_NAME})', out.strip() == EMMC_NAME, out.strip())
    rc, _ = ssh_run('grep -q mmcblk0p5 /proc/partitions')
    check('production partition mmcblk0p5 present', rc == 0)
    rc, out = ssh_run('df /overlay 2>/dev/null | tail -1')
    check('/overlay on fitrw', rc == 0 and 'fitrw' in out, out.split()[0] if out else '')
    if EXPECTED_VER:
        rc, out = ssh_run('cat /etc/knots/product_version 2>/dev/null')
        check(f'product_version={EXPECTED_VER}', out.strip() == EXPECTED_VER, out.strip())
    rc, out = ssh_run('mount | grep /mnt/bitcoin')
    if rc != 0:
        print('WARN  /mnt/bitcoin not mounted — NVMe absent or not factory-prepped yet?')
    rc, out = ssh_run('a=$(cat /etc/knots/node-impl 2>/dev/null); '
                      'b=$(cat /mnt/bitcoin/.node-impl 2>/dev/null); '
                      '[ -n "$a" ] && [ "$a" = "$b" ] && echo match')
    if out.strip() != 'match':
        print('WARN  node-impl dual-persist mismatch or files absent (B15) — check after first Knots run')

    if fails:
        print('\nverification had FAILs — see above; serial log may help')
        sys.exit(1)
    print('''
=== eMMC PRODUCTION BOOT VERIFIED (next: phase 4, label secret) ===
Unit now boots production from eMMC. DIP stays A=1 B=0, no SD.
  Node UI : http://192.168.1.254/
  LuCI    : http://192.168.1.254:8080
Insert the factory-prepped M.2 (if not already) for chain data; first boot
regenerates identity (peers/onion/wallets/cookie) and Knots catches tip.''')

def phase4(ser):
    step('PHASE 4: provision the per-device factory secret (label password)')
    key = os.environ.get('KNOTS_FACTORY_KEY_FILE', '')
    if not key:
        # Default NO even under -y (safety prompt, T2): an unlabelled unit ships
        # with Wi-Fi off and the legacy admin password.
        ask('No KNOTS_FACTORY_KEY_FILE — ship this unit UNLABELLED (Wi-Fi off until Setup, '
            'admin password knotsnode21)?', default=False) or die('no factory key', 1)
        print('Unit left UNLABELLED.')
        ensure_ssh(ser, attempts=1) and remove_station_key()
        return
    ensure_ssh(ser) or die('no ssh to the unit — check the cable / console login', 1)
    env = dict(os.environ, ROUTER_SSH=ROUTER_SSH,
               SSH_OPTS=' '.join(SSH_BASE + ['-o', 'ConnectTimeout=6']))
    r = subprocess.run([os.environ['PROVISION']], env=env)
    if r.returncode != 0:
        die('provisioning failed — fix and resume with --from-phase 4', 1)
    # Shipped units must never trust the factory station.
    remove_station_key() or die('station key still on the unit — remove it before shipping', 1)

def clear_old_secret(ser):
    step('LAB ONE-OFF: clear an old provisioning from this board (eMMC U-Boot env)')
    print('The unit must boot from its current eMMC: DIP SW3 A=1 B=0, no SD card.')
    ask('Power the unit OFF, set DIP A=1 B=0, then answer Y and power it ON within 60 s. Ready?',
        default=True) or die('cancelled', 1)
    state, text = freeze_menu(ser, 120)
    if state in (None, 'linux'):
        die('missed U-Boot (no autoboot countdown seen) — power-cycle and try again', 1)
    if state == 'menu':
        enter_shell(ser, text)
    out = strip_ansi(shell_cmd(ser, 'printenv knots_secret', 15))
    if 'knots_secret=' not in out:
        print('No knots_secret in this board\'s U-Boot env — nothing to clear.')
    else:
        shell_cmd(ser, 'env delete knots_secret', 15)
        shell_cmd(ser, 'saveenv', 30)
        out = strip_ansi(shell_cmd(ser, 'printenv knots_secret', 15))
        if 'knots_secret=' in out:
            die('knots_secret is still set — check the U-Boot env by hand', 1)
        print('Old knots_secret deleted (MAC kept).')
    mac = re.search(r'ethaddr=([0-9a-fA-F:]{17})', strip_ansi(shell_cmd(ser, 'printenv ethaddr', 15)))
    print(f'ethaddr: {mac.group(1) if mac else "(none — U-Boot will create one)"}')
    print('''
Done. Now: power OFF, insert the SD card, set DIP SW3 A=1 B=1 (SD), power ON,
wait ~2 min, then run this script again without --clear-old-secret.''')

def uboot_info(ser):
    step('READ-ONLY: U-Boot environment, eMMC and partition table')
    ask('Power the unit OFF, then answer Y and power it ON within 60 s. Ready?', default=True) or die('cancelled', 1)
    state, text = freeze_menu(ser, 120)
    if state in (None, 'linux'):
        die('missed U-Boot (no autoboot countdown seen) — power-cycle and try again', 1)
    if state == 'menu':
        enter_shell(ser, text)
    for c in ('printenv', 'mmc dev 0', 'mmc info', 'part list mmc 0'):
        print(f'\n----- {c}')
        shell_cmd(ser, c, 30)
    print('\nNothing was written. The unit is at the U-Boot prompt: power it OFF (or type "reset").')

def main():
    print(f'eMMC productionise: port={PORT} ssh={ROUTER_SSH} '
          f'expect_ver={EXPECTED_VER or "?"} start_phase={START_PHASE}')
    ser = serial.Serial(PORT, BAUD, timeout=0.1)
    try:
        ser.set_buffer_size(rx_size=65536)
    except Exception:
        pass
    if UBOOT_INFO:
        try:
            uboot_info(ser)
        finally:
            ser.close()
        return
    if CLEAR_SECRET:
        try:
            clear_old_secret(ser)
        finally:
            ser.close()
        return
    try:
        for n, fn in ((1, phase1), (2, phase2), (3, phase3), (4, phase4)):
            if START_PHASE <= n <= END_PHASE:
                CURRENT_PHASE[0] = n
                fn(ser)
        if END_PHASE < 4:
            print(f'\nStopped after phase {END_PHASE} (--to-phase). '
                  f'Continue later with: --from-phase {END_PHASE + 1}')
    except KeyboardInterrupt:
        # Resume at the phase that was interrupted, not the next one: skipping
        # an unfinished phase 1 would install whatever older image is on NAND
        # (review T10).
        print(f'\nInterrupted in phase {CURRENT_PHASE[0]}. Resume with: '
              f'--from-phase {CURRENT_PHASE[0]}')
        sys.exit(130)
    finally:
        ser.close()

main()
PY
