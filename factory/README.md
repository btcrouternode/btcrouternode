# Factory tooling

**Producing a unit:** `factory/PRODUCTION.md` (factory station runbook).
Station setup: `make factory-station STATION=user@host`, then on the station
`~/rnode-factory/factory/station-setup.sh` (`--test-factory-key` for a
simulation, `--create-factory-key` for the real key).

# Factory M.2 imaging (P4)

**IDs:** S5–S6, D3, NF5  
**Do not** commit chain data or `.factory-ready` seals with secrets into git.

## Flow

1. Golden unit: sync Knots to tip on pinned version.
2. Stop `bitcoind` on golden.
3. Capture datadir (preferred) or whole disk:
   ```bash
   ./factory/capture-m2.sh --mode datadir --src /mnt/bitcoin \
     --out ./out/m2-golden --knots-ver v29.3.knots20260507
   ```
4. Flash blank 1 TB NVMe on the station:
   ```bash
   sudo ./factory/flash-m2.sh --mode datadir \
     --image ./out/m2-golden.tar.zst --device /dev/nvme1n1 \
     --confirm FLASH_M2
   ```
5. Assemble unit (SD system image + flashed M.2). First boot:
   - mounts M.2 (factory/prepared → mount only)
   - `identity-regen.sh` drops peers/onion/wallets/cookie once
   - Knots starts and catches tip

## Never clone as shared identity

Removed on capture and/or regen: `peers.dat`, onion keys, wallets, `.cookie`, banlists.

## Checksums

`capture-m2.sh` writes `*.sha256` beside the archive. Verify before flash in production.

## Per-device label password (P1 — decision D1)

Every unit gets its own admin + Wi-Fi password, printed on its label:

    password = HMAC-SHA256(factory key, ethaddr)  →  xxxx-xxxx-xxxx

`ethaddr` is the unit's MAC in its U-Boot env (on the BPI-R4 it is generated
by U-Boot on first boot — not a burned-in ID). The password is stored in the
U-Boot env as `knots_secret` (eMMC `mmcblk0p1`), which factory reset and
`sysupgrade -n` never touch.

**Factory key — generate once, keep safe, never commit:**

```bash
mkdir -p ~/knots-factory && cd ~/knots-factory
( umask 077; head -c 32 /dev/urandom > factory.key )   # back it up offline
export KNOTS_FACTORY_KEY_FILE=~/knots-factory/factory.key
```

Anyone holding the key can compute every unit's label password from its MAC
(which the unit broadcasts), so treat it like a signing key. Losing it only
means you cannot re-derive old labels; new units can use a new key.

**Provisioning** runs as phase 4 of `install-emmc-from-sd.sh` when
`KNOTS_FACTORY_KEY_FILE` is set (without it the installer asks before
shipping an UNLABELLED unit: Wi-Fi off until Setup, admin `knotsnode21`).
Re-provision / relabel a single unit:

```bash
KNOTS_FACTORY_KEY_FILE=… ROUTER_SSH=root@192.168.1.254 ./factory/provision-secret.sh
# --force only when deliberately relabelling (different existing secret)
```

It prints the label and appends it to `~/knots-factory/labels.csv`
(`KNOTS_LABELS_CSV`; contains passwords — mode 600, gitignored).
If a unit's U-Boot env is ever wiped, restore `ethaddr` from the label via the
U-Boot console (`setenv ethaddr …; saveenv`) and re-run provisioning.

## Production install: SD → eMMC (scripted, DOC3a)

`./factory/install-emmc-from-sd.sh` drives the full SD → NAND → eMMC path over
the USB serial (`PORT=/dev/ttyUSB0`), with exactly **two** prompted physical
steps (each after a script-initiated power-down; it then watches the serial for
the next boot):

1. DIP **NAND** `A=0 B=1` + **remove SD** + power on.
2. DIP **eMMC** `A=1 B=0` + power on.

Phases: menu **7** from SD U-Boot → NAND U-Boot guards (eMMC visible as
`8GTF4R`; F28: NAND `emmc_install` carries the 7391 GPT `0x00e8f820`) →
`run emmc_init` → partition check → ssh verification (`root=/dev/fit0`,
`mmcblk0p5`, fitrw overlay, product version). Never touches NVMe (NF8).

Resume after interruption with `--from-phase 2|3`. Manual SOP / troubleshooting:
`docs/FACTORY_EMMC_INSTALL.md`.

## eMMC restore (lab — after bad manual GPT)

If eMMC boot BL2 panics `Failed to initialize GPT partitions`, do **not** hand-build GPT.

1. DIP **NAND** `A=0 B=1`, SD out, serial @ 115200.
2. U-Boot shell (menu **0**): `mmc dev 0` → `run emmc_init`  
   Or: `./factory/restore-emmc-via-serial.sh` (= `install-emmc-from-sd.sh --from-phase 2`:
   eMMC + F28 guards, waits up to 600 s for `emmc_init`, verifies the GPT, then
   watches the eMMC boot). **Do not power off until it says so.**
3. Power off → DIP **eMMC** `A=1 B=0` → verify `root=/dev/fit0`.

Reference primary GPT (64 sectors): `factory/emmc-gpt-primary-64.bin`.  
Every `make image` regenerates it from the SD image as
`bin/targets/mediatek/filogic/bpi-r4-phase2-<ver>-emmc-gpt-primary-64.bin`
(listed in that build's `.sha256`) and fails the build unless it verifies —
MBR @ LBA 0, header @ LBA 1, CRCs, backup LBA for `ROOTFS_PARTSIZE_MIB`
(7391 → `20f8e800`) — and equals the committed copy (G4;
`build/extract-emmc-gpt.py`, `UPDATE_GPT_REF=1` to refresh deliberately).  
Details: `factory/restore-emmc-from-nand.md`, `docs/FIX_F28_EMMC_GPT_OVERFLOW.md` (F30).

## Refresh SPI-NAND bridge from SD (menu 7)

So future `emmc_init_bl` / menu **9** writes **7391** GPT from NAND `emmc_install`:

1. SD must be flashed with the current **`…sdcard.img.gz`** (`make flash-sd DEVICE=/dev/sdX`).
2. DIP **SD** `A=1 B=1`, U-Boot → **7** (*Install … to NAND*).  
   Host helper: `./factory/flash-nand-from-sd-menu7.sh` — phase 1 of
   `install-emmc-from-sd.sh` (menu entry parsed, SD version + embedded GPT
   blob checked, confirmation, real success/failure detection).
3. Verify on NAND U-Boot: `ubi read 0x50000000 emmc_install 0x800000` then `md.l 0x50500220 1` → **`0x00e8f820`** (not `0x00e98020`).
4. If still `0xe98020`, SD image is stale — re-flash SD or patch `emmc_install` @ `+0x500000` with `emmc-gpt-primary-64.bin` and `ubi write … 0x800000`.
5. Remove SD; production stays on **eMMC** (`A=1 B=0`).
