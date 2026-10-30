#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# F23 — wallet-cgi /api stubs must be executable for uhttpd CGI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
API="$ROOT/files/usr/libexec/knots/wallet-cgi/api"
fail=0
for f in "$API"/*; do
  [ -f "$f" ] || continue
  if [ ! -x "$f" ]; then
    echo "FAIL: not executable: $f"
    fail=1
  else
    echo "OK: executable $(basename "$f")"
  fi
done
[ -x "$API/node" ] || { echo "FAIL: api/node missing or not +x"; fail=1; }
for f in node-impl-api.sh settings-api.sh setup-api.sh; do
  p="$ROOT/files/usr/libexec/knots/$f"
  if [ ! -x "$p" ]; then
    echo "FAIL: not executable: $p"
    fail=1
  else
    echo "OK: executable $f"
  fi
done
# Phase-3 APIs deleted (review S9 / D5, 2026-10-10): dead code with RPC
# JSON injection and no auth/POST/LAN gates — must not ship.
for f in wallet-api.sh external-api.sh lightning-api.sh privacy-api.sh \
	lightning-ensure.sh privacy-ensure.sh; do
  ! test -e "$ROOT/files/usr/libexec/knots/$f" || {
    echo "FAIL: $f must not exist (S9)"; fail=1; }
done
for f in wallet external lightning privacy; do
  ! test -e "$API/$f" || { echo "FAIL: wallet-cgi/api/$f must not exist (S9)"; fail=1; }
done
# storage-api.sh retired with S7 — must not exist
! test -e "$ROOT/files/usr/libexec/knots/storage-api.sh" || {
  echo "FAIL: storage-api.sh must not exist (S7)"; fail=1
}
! test -e "$API/storage" || {
  echo "FAIL: wallet-cgi/api/storage must not exist (S7)"; fail=1
}
[ "$fail" -eq 0 ] || exit 1
echo "PASS: wallet-cgi API stubs executable"
