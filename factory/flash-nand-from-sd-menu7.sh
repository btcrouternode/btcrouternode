#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# SD U-Boot "Install … to NAND" (stock menu 7): bootloader, recovery,
# production + emmc_install blob → SPI-NAND.
#
# T3 (review 2026-10-11): this used to be its own serial script that sent "7"
# blind, treated ANY "Press ENTER" as success, never asked, and still talked
# about build .48. It is now phase 1 of factory/install-emmc-from-sd.sh, which
# parses the menu for the NAND entry, checks the SD image version and the
# embedded eMMC GPT blob (F28), asks before writing, and fails on
# "not detected" / "Installation abort" / errors.
#
# Usage: factory/flash-nand-from-sd-menu7.sh [-y]
# Env:   PORT=/dev/ttyUSB0 ROUTER_SSH=root@192.168.1.254 WAIT_SEC=240
# Then:  power off, REMOVE SD, DIP SW3 A=0 B=1 (SPI-NAND), power on to verify —
#        or continue to eMMC with install-emmc-from-sd.sh --from-phase 2.
set -euo pipefail
exec "$(dirname "$0")/install-emmc-from-sd.sh" --from-phase 1 --to-phase 1 "$@"
