#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-ID-1 — identity regen on factory-sealed datadir (S6 / H7a / B9).
# H8: executes the REAL files/usr/libexec/knots/identity-regen.sh in a sandbox
# (base paths sed-rewritten; no heredoc clone, so a regression in the real
# script fails here).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REGEN="$ROOT/files/usr/libexec/knots/identity-regen.sh"
chmod +x "$REGEN"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Sandbox copy: rewrite ONLY the absolute base paths. Everything else —
# markers, deletion list, both-layout loop — is the shipped logic.
sed "s|/mnt/bitcoin|$SANDBOX/m2|g; s|/etc/knots|$SANDBOX/etcknots|g" \
	"$REGEN" >"$SANDBOX/identity-regen.sh"
chmod +x "$SANDBOX/identity-regen.sh"
grep -q "$SANDBOX/m2" "$SANDBOX/identity-regen.sh" || {
	echo "FAIL: sandbox sed did not apply"; exit 1;
}

# logger is not a base path — stub it so the run does not depend on host syslog
mkdir -p "$SANDBOX/bin"
printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/bin/logger"
chmod +x "$SANDBOX/bin/logger"
PATH="$SANDBOX/bin:$PATH"

M2="$SANDBOX/m2"
ETC="$SANDBOX/etcknots"
FLAG="$ETC/identity-regen.done"
M2_FLAG="$M2/.identity-regen.done"

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- (5) No .factory-ready → exit 0 doing nothing -------------------------
mkdir -p "$M2"
echo x >"$M2/peers.dat"
"$SANDBOX/identity-regen.sh"
[ -f "$M2/peers.dat" ] || fail "no-marker run must not delete peers.dat"
[ ! -e "$FLAG" ] || fail "no-marker run must not write done flag"
[ ! -e "$M2_FLAG" ] || fail "no-marker run must not write M.2 flag"
rm -f "$M2/peers.dat"

# --- (1) First run with .factory-ready: regen identity, keep chain --------
touch "$M2/.factory-ready"
# Identity material at mount root (appliance layout) …
echo x >"$M2/peers.dat"
echo x >"$M2/.cookie"
echo x >"$M2/onion_v3_private_key"
echo x >"$M2/banlist.json"
echo x >"$M2/banlist.dat"
mkdir -p "$M2/wallets/appliance" "$M2/walletdir"
echo x >"$M2/wallets/appliance/wallet.dat"
# … and inside the datadir subdir layout (both loops of the real script)
mkdir -p "$M2/bitcoin"
echo x >"$M2/bitcoin/peers.dat"
# Chain data must survive
mkdir -p "$M2/blocks" "$M2/chainstate"
echo x >"$M2/blocks/blk00000.dat"
echo x >"$M2/chainstate/000001.ldb"

"$SANDBOX/identity-regen.sh"

for f in peers.dat .cookie onion_v3_private_key banlist.json banlist.dat; do
	[ ! -e "$M2/$f" ] || fail "first run left $f"
done
[ ! -e "$M2/wallets" ] || fail "first run left wallets/"
[ ! -e "$M2/walletdir" ] || fail "first run left walletdir/"
[ ! -e "$M2/bitcoin/peers.dat" ] || fail "first run left datadir-subdir peers.dat"
[ -f "$M2/blocks/blk00000.dat" ] || fail "blocks/ must survive regen"
[ -f "$M2/chainstate/000001.ldb" ] || fail "chainstate/ must survive regen"
[ -f "$M2/.factory-ready" ] || fail ".factory-ready must survive regen"

# --- (2) BOTH done markers set --------------------------------------------
[ -f "$FLAG" ] || fail "etc done marker missing after first run"
[ -f "$M2_FLAG" ] || fail "M.2 done marker missing after first run (H7a/B9)"

# --- (3) Second run is a no-op --------------------------------------------
mkdir -p "$M2/wallets/appliance"
echo x >"$M2/wallets/appliance/wallet.dat"
"$SANDBOX/identity-regen.sh"
[ -f "$M2/wallets/appliance/wallet.dat" ] || fail "second run deleted a wallet"

# --- (4) B9: overlay wiped (etc marker gone), M.2 marker present → no-op --
rm -f "$FLAG"
"$SANDBOX/identity-regen.sh"
[ -f "$M2/wallets/appliance/wallet.dat" ] || \
	fail "B9: overlay wipe must not re-run regen (wallet deleted)"

echo "PASS T-ID-1"
