#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-FAC-2 — install-emmc-from-sd.sh state machine, tested against a pty-simulated
# BPI-R4 (U-Boot menus, emmc_init, Linux boot). No hardware needed.
# Scenarios: happy path, F28 (7408 GPT) guard, SD-still-inserted guard,
# unknown GPT word under -y (safety prompt must still refuse — review T2).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

exec python3 - "$ROOT" << 'PY'
import os, pty, re, select, subprocess, sys, time

ROOT = sys.argv[1]
SCRIPT = f'{ROOT}/factory/install-emmc-from-sd.sh'

SD_MENU = """\r\n      ( ( ( OpenWrt ) ) )  [SD card]\r\n\r\n\
      1. Initialize environment.\r\n\
      2. Boot system via TFTP.\r\n\
      3. Boot production system from SD card.\r\n\
      4. Boot recovery system from SD card.\r\n\
      5. Load production system via TFTP then write to SD card.\r\n\
      6. Load recovery system via TFTP then write to SD card.\r\n\
      7. Install bootloader, recovery and production to NAND.\r\n\
      8. Reboot.\r\n\
      9. Reset all settings to factory defaults.\r\n\
      0. Exit\r\n\r\n\
Press UP/DOWN to move, ENTER to select, ESC to quit\r\n"""
NAND_MENU = """\r\n      ( ( ( OpenWrt ) ) )  [SPI-NAND]\r\n\r\n\
      1. Initialize environment.\r\n\
      2. Boot system via TFTP.\r\n\
      3. Boot production system from NAND.\r\n\
      4. Boot recovery system from NAND.\r\n\
      5. Load production system via TFTP then write to NAND.\r\n\
      6. Load recovery system via TFTP then write to NAND.\r\n\
      7. Load BL31+U-Boot FIP via TFTP then write to NAND.\r\n\
      8. Load BL2 preloader via TFTP then write to NAND.\r\n\
      9. Install bootloader, recovery and production to eMMC.\r\n\
      a. Reboot.\r\n\
      b. Reset all settings to factory defaults.\r\n\
      0. Exit\r\n\r\n\
Press UP/DOWN to move, ENTER to select, ESC to quit\r\n"""
LINUX_BOOT = '[    0.000000] Linux version 6.6.110 (builder@buildhost)\r\n' \
    '... boot ...\r\nPlease press Enter to activate this console.\r\n'

class Sim:
    def __init__(self, fd):
        self.fd = fd; self.buf = b''; self.log = b''
    def write(self, s):
        os.write(self.fd, s.replace('\n', '\r\n').encode())
    def expect(self, pat, timeout=20):
        rx = re.compile(pat.encode())
        end = time.time() + timeout
        while time.time() < end:
            m = rx.search(self.buf)
            if m:
                got = self.buf[:m.end()]; self.buf = self.buf[m.end():]
                self.log += got; return got
            if not select.select([self.fd], [], [], 0.5)[0]:
                continue
            try:
                chunk = os.read(self.fd, 1024)
            except OSError:
                break
            if not chunk:
                break
            self.buf += chunk
        raise RuntimeError(f'timeout waiting for {pat!r}; tail={self.buf[-200:]!r}')

def boot_to_menu(sim, menu, countdown='Hit any key to stop autoboot:  3 '):
    sim.write('U-Boot 2024.10-OpenWrt\r\n' + countdown)
    sim.expect(' ')
    sim.write(menu)

def run(scenario):
    mfd, sfd = pty.openpty()
    slave = os.ttyname(sfd)
    # ssh -> 127.0.0.1 (refused): all ssh/poweroff steps take the manual
    # fallback, so this harness only exercises the serial state machine.
    env = dict(os.environ, PORT=slave, WAIT_SEC='25', SSH_WAIT_SEC='5',
               ROUTER_SSH='root@127.0.0.1')
    proc = subprocess.Popen([SCRIPT, '-y'], env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    sim = Sim(mfd)
    try:
        # ---- phase 1: SD boot, menu 7, reset, Linux boot (manual poweroff) ----
        time.sleep(1.5)  # let ssh preflight fail first
        boot_to_menu(sim, SD_MENU)
        sim.expect(r'7\n')
        sim.write('Installing bootloader, recovery and production to NAND ...\r\n'
                  'emmc_install written: OK\r\nInstallation complete\r\n'
                  'Press ENTER to return to menu')
        sim.expect('\n')
        sim.write(SD_MENU)
        sim.expect(r'0\n')
        sim.write('MT7988> ')
        sim.expect(r'reset\n')
        time.sleep(0.5)
        sim.write(LINUX_BOOT)
        time.sleep(3.0)  # script: ssh probe fails -> manual warning -> PHYS1 -> phase 2 watch

        # ---- phase 2: NAND boot, guards, emmc_init, part list, reset ----
        boot_to_menu(sim, NAND_MENU)
        sim.expect(r'0\n')
        sim.write('MT7988> ')
        sim.expect(r'mmc dev 0\n'); sim.write('switch to partitions #0, OK\r\nMT7988> ')
        sim.expect(r'mmcinfo\n')
        if scenario == 'sdcard':
            sim.write('Device: SD\r\nName: SK64G \r\nCapacity: 59.5 GiB\r\nMT7988> ')
            time.sleep(3); return proc, sim
        sim.write('Device: mmc\r\nName: 8GTF4R \r\nCapacity: 7.3 GiB\r\nMT7988> ')
        sim.expect(r'ubi part ubi\n'); sim.write('ubi0: attaching\r\nMT7988> ')
        sim.expect(r'ubi read 0x50000000 emmc_install 0x800000\n')
        sim.write('Read 8388608 bytes from volume emmc_install\r\nMT7988> ')
        sim.expect(r'md\.l 0x50500220 1\n')
        word = {'f28': '00e98020', 'unknown': 'deadbeef'}.get(scenario, '00e8f820')
        sim.write(f'50500220: {word}    \r\nMT7988> ')
        if scenario in ('f28', 'unknown'):
            time.sleep(3); return proc, sim
        sim.expect(r'run emmc_init\n')
        sim.write('Read 8388608 bytes from volume emmc_install to 0000000050000000\r\n'
                  'MMC write: dev # 0, block # 0, count 1024 ... 1024 blocks written: OK\r\n'
                  '## Checking hash(es) for FIT Image at 50000000 ...\r\n'
                  '   Hash(es) for Image 0 (kernel-1): crc32+ sha1+\r\n'
                  'Saving Environment to UBI... OK\r\nMT7988> ')
        sim.expect(r'part list mmc 0\n')
        sim.write('Partition Map for MMC device 0  --   Partition Type: EFI\r\n'
                  'Part\tStart LBA\tEnd LBA\tName\r\n'
                  '\t4\t0x0001b000\t0x0001ffff\t"recovery"\r\n'
                  '\t5\t0x00020000\t0x00e8f7ff\t"production"\r\nMT7988> ')
        sim.expect(r'reset\n')
        time.sleep(0.5)
        sim.write(LINUX_BOOT)
        time.sleep(3.0)  # script: ssh probe fails -> manual warning -> PHYS2 -> phase 3 watch

        # ---- phase 3: production boot (ssh times out in harness -> exit 2) ----
        sim.write(LINUX_BOOT)
        time.sleep(8)
        return proc, sim
    finally:
        try:
            out, _ = proc.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill(); out, _ = proc.communicate()
        sim.output = out

def verdict(name, proc, sim, want_code, wants):
    ok = proc.returncode == want_code and all(w in sim.output for w in wants)
    print(f'{"PASS" if ok else "FAIL"}  {name}  (exit={proc.returncode})')
    if not ok:
        print('--- script output tail ---')
        print(sim.output[-3000:])
    return ok

allok = True
p, s = run('happy')
allok &= verdict('happy path', p, s, 2, [
    'NAND install = menu item 7', 'PHYSICAL STEP 1 of 2',
    'guard OK] boot menu is the SPI-NAND U-Boot',
    'guard OK] mmc0 is the eMMC', 'guard OK] NAND emmc_install carries the 7391 GPT',
    'guard OK] eMMC has production + recovery partitions', 'PHYSICAL STEP 2 of 2',
    'PHASE 3'])
p, s = run('f28')
allok &= verdict('F28 guard', p, s, 1, ['BROKEN 7408 GPT'])
p, s = run('unknown')
allok &= verdict('unknown GPT word refused under -y', p, s, 1,
                 ['safety prompt; -y does not override', 'unverified GPT blob'])
p, s = run('sdcard')
allok &= verdict('SD-still-inserted guard', p, s, 1, ['not visible on mmc0'])

print('PASS T-FAC-2' if allok else 'FAIL T-FAC-2')
sys.exit(0 if allok else 1)
PY
