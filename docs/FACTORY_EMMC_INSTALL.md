# Factory / lab: install Phase 2 system to eMMC (DOC3a / R5a)

**Authority:** REQUIREMENTS R5, R5a, DOC3a, NF8  
**Do not wipe M.2** (`/dev/nvme0n1`) — chain data stays on NVMe.

> **Scripted path:** `factory/install-emmc-from-sd.sh` orchestrates this exact
> procedure over the serial console — it powers the router down, prompts for the
> two DIP steps (SD→NAND, NAND→eMMC), watches the serial for each next boot, and
> verifies the eMMC production boot over ssh. This SOP remains the manual
> reference and troubleshooting guide.

## Why you cannot flash eMMC while booted from SD

On BPI-R4, **microSD and eMMC share one MMC controller**. With an SD inserted, the kernel only sees the SD (this lab unit shows `mmcblk0` as **SK64G**). The **8 GB eMMC is hidden** until the SD is removed and you boot from NAND or eMMC.

Therefore the OpenWrt path is always:

**SD → SPI-NAND (bridge) → eMMC → remove SD → boot eMMC**

SPI-NAND (~128 MB) is **bootloader / recovery / install bridge only** — not the permanent appliance root (LXC+Knots is too big).

## Boot DIP switches (SW3)

| Boot media | A | B | Notes |
|------------|---|---|--------|
| **microSD** | 1 (up) | 1 (up) | Current lab mode |
| **SPI-NAND** | 0 (down) | 1 (up) | Required middle step |
| **eMMC** | 1 (up) | 0 (down) | Production end position |

(A/B are logic values per OpenWrt/Banana Pi docs. The physical direction depends on board revision: on **v1.x** boards 1 = **down** (toward PCB), on v0 it was reversed — always match the 0/1 printed on the switch / silkscreen, not this table's old up/down note.)

## Artifacts (from `make image`)

Under `bin/targets/mediatek/filogic/`:

| File | Role |
|------|------|
| `*bananapi_bpi-r4-sdcard.img.gz` | Boot/install media — GPT **production** sized to eMMC (**R5b**) |
| `*bananapi_bpi-r4-squashfs-sysupgrade.itb` | Production FIT (squashfs base; also embedded in SD image flow) |
| `*emmc-preloader.bin` / `*emmc-bl31-uboot.fip` | eMMC bootloader pieces (U-Boot menu uses these from the image) |

Phase 2 example: product **`24.10.8.29.3.42`** with **`ROOTFS_PARTSIZE_MIB=7391`** (see `build/version.env`; **F28** — 7408 overflowed 8GTF4R).

### Lab parity (R5b)

SD and eMMC share the same production recipe: immutable **squashfs** (`/rom`) + writable **fitrw** overlay. The SD image does **not** use the full physical SD card — only an eMMC-matched GPT (~64 MiB boot pieces + **7391 MiB** production). That is intentional so package/overlay testing on SD matches what lands on eMMC after DOC3a install.

## Procedure (serial console recommended)

Keep USB-TTL on `/dev/ttyUSB0` at **115200 8N1**. You need the **U-Boot boot menu** (interrupt autoboot when the menu appears).

### 1. Prep (chain preserve)

1. Confirm IBD/tip is OK if you care about uptime — install will reboot several times.  
2. **Do not** run storage wipe / `mkfs` on NVMe.  
3. SD must already hold the **Phase 2** `sdcard.img` (or re-flash it on a PC).  
4. DIP = **SD** (`A=1, B=1`). Power on; confirm OpenWrt boots from SD (`root=/dev/fit0`).

### 2. Install from SD → SPI-NAND

1. Reboot and enter **U-Boot boot menu**.  
2. Select approximately:  
   **“Install bootloader, recovery and production to NAND”**  
   (menu number varies by U-Boot build — read the labels).  
3. Wait until install finishes.  
4. Power off. **Remove microSD** (so eMMC can appear later).  
5. Set DIP = **SPI-NAND** (`A=0, B=1`). Power on.  
6. Confirm you boot from NAND (U-Boot/OpenWrt recovery or production on NAND).

### 3. Install from NAND → eMMC

1. Enter **U-Boot boot menu** again.  
2. Select approximately:  
   **“Install bootloader, recovery and production to eMMC”**.  
3. Wait until finished.  
4. Power off.  
5. Set DIP = **eMMC** (`A=1, B=0`). Leave **SD out**. Power on.

### 4. Verify production boot

On serial / LAN after eMMC boot:

```sh
cat /proc/cmdline          # should NOT be SD-only lab path once on eMMC
lsblk                      # expect ~8G mmcblk0 (eMMC), nvme0n1 = M.2
mount | grep bitcoin       # /mnt/bitcoin from NVMe
cat /etc/knots/product_version
cat /mnt/bitcoin/.node-impl
cat /etc/knots/node-impl   # should match (B15 dual persist)
```

Checks:

- Knots/Node UI on `http://192.168.1.254/`  
- LuCI on `:8080`  
- Chain still on M.2 (blocks present; tip advances / at tip)  
- Selected impl (Knots/Core) still correct  

Optional later: LuCI **System → Backup/Flash** with `*-squashfs-sysupgrade.itb` to refresh production partition **without** touching NVMe (keep settings if appropriate).

## If install fails / eMMC not seen

- SD still inserted while trying to use eMMC → remove SD, boot NAND first.  
- Wrong DIP → board sits in wrong boot media.  
- Need serial — U-Boot menu is the supported path for stock OpenWrt BPI-R4.  
- Menu 9 “succeeds” but eMMC has no `production`/`recovery` and boots TFTP → GPT too large for the chip (**F28**). Use an image with **`ROOTFS_PARTSIZE_MIB=7391`**, or repair GPT then run `emmc_init_openwrt` only (do not re-apply a 7408 `emmc_install` header). See `docs/FIX_F28_EMMC_GPT_OVERFLOW.md`.

## Out of scope for this SOP

- Writing eMMC with `dd` from a host PC while SD is the only MMC device (won’t see eMMC).  
- Putting the full LXC+Knots root permanently on SPI-NAND.  
- Wiping or reformatting M.2 as part of eMMC install.
