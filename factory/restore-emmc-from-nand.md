# Restore eMMC after bad manual GPT edits (F28 lab recovery)

**Symptom:** eMMC boot BL2 panic: `Failed to initialize GPT partitions` / `FIP boot source initialization failed`.

**Root cause:** Manual `gpt write` / hand-built GPT placed `EFI PART` at **LBA 0**. OpenWrt/ptgen layout is:

| LBA | Content |
|-----|---------|
| 0 | Protective **MBR** (`0x55AA`) |
| 1 | EFI GPT header (`EFI PART`, `my_lba=1`) |
| 2–33 | Partition entries |

Only the **primary** 64 sectors (32 KiB) are written to eMMC LBA 0 by `emmc_write_hdr`. Backup LBA is metadata (`15267872` for 7391 MiB production on 8GTF4R); ptgen does **not** embed backup sectors in the install blob.

**Do not** hand-build GPT or use `gpt write` with multiple partitions on this U-Boot (only first partition sticks).

## Correct fix (from SPI-NAND boot, SD out)

1. DIP **NAND** `A=0 B=1`, power on, U-Boot menu → **0** (shell) or let autoboot to Linux.
2. From **NAND U-Boot** (`[SPI-NAND]`):

   ```text
   mmc dev 0
   run emmc_init
   ```

   This is menu **9** without the menu: `emmc_init_bl` (BL2 + FIP + primary GPT from NAND `emmc_install` UBI) then `emmc_init_openwrt` (recovery + production FITs from NAND UBI).

   **Important:** `emmc_init_bl` writes the GPT from the NAND **`emmc_install`** UBI volume. If that volume is stale (e.g. from a pre-7391 SD flash), it reinstalls a **7408** header → `gpt verify` fails and `part list` is empty. Fix: re-flash NAND from a **7391** SD (menu **7**) first, **or** write `factory/emmc-gpt-primary-64.bin` to eMMC LBA 0 (64 sectors) and run **`emmc_init_openwrt` only** (skip `emmc_init_bl`).

3. Power off → DIP **eMMC** `A=1 B=0` → boot → verify `root=/dev/fit0`, `lsblk` ~7.3G, M.2 intact.

## Alternative (Linux on NAND, same primary blob)

Primary blob extracted to `factory/emmc-gpt-primary-64.bin` (from sdcard image @ 56 MiB):

```sh
dd if=/tmp/emmc-gpt-primary-64.bin of=/dev/mmcblk0 bs=512 count=64 conv=fsync
```

Then still run **`run emmc_init_openwrt`** from NAND U-Boot to write FITs (or full `run emmc_init` if BL2/FIP may be wrong).

## Authority

`docs/FIX_F28_EMMC_GPT_OVERFLOW.md`, OpenWrt `ptgen.c`, `bananapi_bpi-r4_snand_env` (`emmc_init` / `emmc_write_hdr`).
