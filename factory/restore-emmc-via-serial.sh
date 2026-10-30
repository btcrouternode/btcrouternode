#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Restore eMMC from SPI-NAND U-Boot using official OpenWrt emmc_init (menu 9).
# Use when BL2 panics "Failed to initialize GPT partitions" after manual GPT edits.
# Requires: DIP NAND A=0 B=1, SD removed, pyserial, /dev/ttyUSB0 (override PORT=).
#
# Review T1: this used to send `run emmc_init`, read 60 s of output and print
# "Complete. Power off" — emmc_init takes up to 600 s, so operators powered off
# mid-write and bricked the eMMC. It also had no eMMC-visible or F28 GPT guard.
# The guarded, fully-waited implementation is phase 2 (+ phase 3 verify) of
# install-emmc-from-sd.sh; this is now a thin entry point to it.
#
# Usage: factory/restore-emmc-via-serial.sh [-y]
# Env:   as install-emmc-from-sd.sh (PORT, BAUD, ROUTER_SSH, EMMC_NAME, WAIT_SEC).
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/install-emmc-from-sd.sh" --from-phase 2 "$@"
