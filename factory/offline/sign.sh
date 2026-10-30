#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Sign the staged release — on the offline laptop, booted from the live USB:
#
#   Files → the laptop's drive (127 GB) → home/<user>/rnode-sign → copy the
#   path; Terminal: cd <that path>; sudo bash sign.sh
#
# Then follow the questions (fingerprints, key stick A and its password).
# Staged by the build PC (build/stage-offline.sh); the result lands in
# signed/ next to this file, where the build PC collects it.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
K="$HERE/rnode-keygen"
stop() { printf '\nSTOP: %s\n' "$*"; read -r -p "Press Enter to close. " _; exit 1; }

[ "$(id -u)" = 0 ] || exec sudo bash "$0" "$@"
[ -f "$K/SHA256SUMS" ] && [ -f "$HERE/EXPECTED" ] || stop "this folder is incomplete — ask for it to be staged again"

clear 2>/dev/null || true
echo "RNode — sign a release"
echo "======================"
echo
echo "1. Tools fingerprint (compare with the number the build PC gave you):"
echo
echo "     $(cd "$K" && sha256sum SHA256SUMS | cut -d' ' -f1)"
echo
( cd "$K" && sha256sum -c --quiet SHA256SUMS ) || stop "the tools are damaged — do not sign"
read -r -p "   Is it the same number? [y/N] " a
[ "$a" = y ] || [ "$a" = Y ] || stop "fingerprint not confirmed — nothing was signed"

cd "$K" && bash sign-release.sh || stop "signing did not finish — nothing was signed"
echo
read -r -p "Signed. Write down the signed fingerprint above, then press Enter and shut the laptop down. " _
