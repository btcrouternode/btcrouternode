# Producing RNode units (factory station runbook)

**Normal way: the station screen.** On the station: desktop shortcut *RNode
Factory Station* (or `~/rnode-factory/factory/station/start-station.sh`) →
http://127.0.0.1:8099/ — batch size (remembers the last one), detect the
routers on their serial adapters, confirm the number, then follow the screen:
power on each router (DIP A=1 B=0, no SD), it installs by **TFTP** (preloader,
U-Boot, production), boots, verifies, provisions over the console, then the
sticker step (PNG on screen, blue LED, WPS press). Needs a board whose eMMC
already has a working U-Boot with the 7391 partition table (checked first);
brand-new blank boards still need the SD → NAND route below.

The sections below are the manual / command-line route.

# Producing one RNode unit — command line

Station: the production laptop, prepared with `factory/station-setup.sh`.
One unit at a time, cabled **directly** to the station (the unit is always
`192.168.1.254` — never have a second router on this cable).

The M.2 arrives **already prepared** (cloned chain data, `factory/README.md`
"Factory M.2 imaging"); this runbook does not touch it.

## 0. Before you start

```bash
. ~/knots-factory/station.env
$RNODE_FACTORY_HOME/factory/station-setup.sh --check
```

All lines should be **OK** (serial adapter, SD reader, Ethernet on
192.168.1.x, factory key). `factory-TEST.key` = simulation only.

## Re-using a board (lab one-off)

A board that was provisioned before keeps its old secret in the U-Boot env and
provisioning would (rightly) refuse it. With the board still booting its old
eMMC (DIP A=1 B=0, no SD):

```bash
$RNODE_FACTORY_HOME/factory/install-emmc-from-sd.sh --clear-old-secret
```

## 1. Write the SD card

```bash
lsblk -d -o NAME,SIZE,TRAN,RM      # find the SD card, e.g. sdc
$RNODE_FACTORY_HOME/factory/flash-sd.sh /dev/sdX $RNODE_FACTORY_HOME/images/<version>/bpi-r4-phase2-<version>-sdcard.img.gz
```

It refuses anything that is not a removable SD/USB disk and asks you to type
the device name. Check the SHA256 first:
`(cd $RNODE_FACTORY_HOME/images/<version> && sha256sum -c --ignore-missing *.sha256)`.

## 2. Assemble and boot from SD

1. M.2 (prepared) in its slot, Wi‑Fi card / antennas, case.
2. USB serial adapter on the 3-pin UART (GND, TX, RX — 115200).
3. Station Ethernet → the unit's **LAN** port.
4. SD card in, DIP **SW3 A=1 B=1** (SD), power on. Wait ~2 min.

## 3. Productionise (SD → NAND → eMMC → provision)

```bash
$RNODE_FACTORY_HOME/factory/install-emmc-from-sd.sh
```

- Logs in on the console with the factory password, installs this station's
  ssh key, and drives everything else.
- Exactly **two** physical steps, each after the script powered the unit off:
  1. DIP **A=0 B=1** (NAND) + **remove the SD** + power on.
  2. DIP **A=1 B=0** (eMMC) + power on.
- Phase 4 derives the unit's password from the factory key, writes it to the
  board, applies it (root + Wi‑Fi `rnode`), prints the **LABEL** and appends
  an inventory line to `~/knots-factory/labels.csv` (no password), then
  **removes the station key**.
- Interrupted? It prints the `--from-phase N` to resume with.

## 4. Stickers — the right one on the right router

Firmware .103 or later. With every router of the batch built, booted from eMMC
and on its own bay serial line:

```bash
$RNODE_FACTORY_HOME/factory/label-batch.py --bays /dev/ttyUSB0[,/dev/ttyUSB1,…]
```

For each bay in turn it prints that unit's sticker and **flashes that router's
blue LED** (all others dark). Stick it on the flashing router and **press that
router's WPS button**:

- same router → ✔ confirmed, next sticker;
- another router → ✘ **stops**: both flash, peel the sticker and fix it.

During labelling the WPS button only identifies the router (no reboot, no
reset); this "label mode" is in RAM and expires on its own. Stickers are PNGs
in `~/knots-factory/batches/<time>/` until a printer is set
(`--print-cmd '… {png}'`); the batch report is `report.csv` there.

## 5. Final checks (customer view)

1. From a laptop: join Wi‑Fi **rnode** with the label password → Setup opens
   by itself (or `http://rnode-XXXX.local/`, `http://192.168.1.254/`).
2. Do **not** finish Setup on units for sale — the station shuts each router
   down cleanly ("✔ off — ready to box").

## 6. Passwords are never stored — lost stickers

Every sticker password is calculated from the **factory key** and the router's
MAC. `~/knots-factory/labels.csv` is an inventory only: date, MAC, router
name, firmware and `key_id` (which factory key made it; `TEST-…` for test
units) — **no passwords**. The factory key is the one secret: back it up
offline once (see `station-setup.sh --create-factory-key`).

Lost sticker (customer support, damaged label): station screen → **Replace a
lost sticker** → router name (`rnode-9e3e` or `9e3e`) or MAC → **Make and print
new sticker**. Or on the command line:

```bash
$RNODE_FACTORY_HOME/factory/recover-sticker.py rnode-9e3e --reason "customer lost sticker"
```

The password is recalculated, the new sticker is **printed at once**
(`KNOTS_LABEL_PRINT_CMD`, `{png}` = the file; no printer yet = the PNG is shown
and kept in `~/knots-factory/recovered/`), and the recovery is logged in
`~/knots-factory/recoveries.csv` (no password). A router made with a different
factory key (TEST vs real) is refused.

Re-label / re-provision one unit: `factory/provision-secret.sh` (see
`factory/README.md`). Troubleshooting the eMMC steps:
`docs/FACTORY_EMMC_INSTALL.md`.
