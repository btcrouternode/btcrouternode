#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Product Phase 2 runtime posture — do not touch /mnt/bitcoin/blocks or chainstate
set -e
CONF=/srv/lxc/knots/rootfs/etc/bitcoin/bitcoin.conf
if [ -f "$CONF" ]; then
  sed -i 's/^disablewallet=.*/disablewallet=1/' "$CONF"
  grep -q '^disablewallet=' "$CONF" || echo 'disablewallet=1' >> "$CONF"
fi
# Disable optional Phase 3 module enable markers (leave data dirs intact)
rm -f /mnt/bitcoin/.lightning-enabled /mnt/bitcoin/.privacy-enabled
# Best-effort stop lightning / privacy helpers if present
if [ -x /usr/libexec/knots/lightning-ensure.sh ]; then
  /usr/libexec/knots/lightning-ensure.sh stop 2>/dev/null || true
fi
if [ -x /usr/libexec/knots/privacy-ensure.sh ]; then
  /usr/libexec/knots/privacy-ensure.sh disable 2>/dev/null || true
fi
if [ -x /usr/libexec/knots/external-rpc.sh ]; then
  /usr/libexec/knots/external-rpc.sh disable 2>/dev/null || true
fi
echo "phase2-posture: ok"
