#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# B19–B21 — install-from / rollback / sha256 / aarch64 ELF gate (host)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make_aarch64_stub() {
  python3 - "$1" <<'PY'
import pathlib, sys
b = bytearray(64)
b[0:4] = b"\x7fELF"
b[4] = 2
b[5] = 1
b[18] = 0xB7
b[19] = 0
pathlib.Path(sys.argv[1]).write_bytes(bytes(b))
PY
  chmod +x "$1"
}

# --- ELF helper (mirrors node-impl.sh) ---
cat >"$TMP/elf.sh" <<'EOF'
is_aarch64_elf() {
  f=$1
  [ -f "$f" ] || return 1
  mag=$(dd if="$f" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$mag" = "7f454c46" ] || return 1
  mach=$(dd if="$f" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$mach" = "b700" ] || [ "$mach" = "00b7" ]
}
EOF
make_aarch64_stub "$TMP/good"
# shellcheck disable=SC1091
. "$TMP/elf.sh"
is_aarch64_elf "$TMP/good"
echo notelf >"$TMP/bad"
if is_aarch64_elf "$TMP/bad"; then echo "FAIL: non-ELF accepted"; exit 1; fi
echo "OK: is_aarch64_elf"

# --- Fake official tarball ---
STAGE="$TMP/pkg/bitcoin-29.4-aarch64-linux-gnu/bin"
mkdir -p "$STAGE"
make_aarch64_stub "$STAGE/bitcoind"
make_aarch64_stub "$STAGE/bitcoin-cli"
TGZ="$TMP/bitcoin-29.4-aarch64-linux-gnu.tar.gz"
tar -czf "$TGZ" -C "$TMP/pkg" bitcoin-29.4-aarch64-linux-gnu
SHA=$(sha256sum "$TGZ" | awk '{print $1}')

M2="$TMP/m2"
BINROOT="$M2/node-bin"
mkdir -p "$BINROOT/core/bin"
echo old >"$BINROOT/core/bin/bitcoind"
chmod +x "$BINROOT/core/bin/bitcoind"
echo "v-old" >"$BINROOT/core/VERSION"

# --- install-from logic (same contract as node-impl.sh) ---
install_one() {
  impl=$1
  tgz=$2
  sha=$3
  confirm=$4
  [ "$confirm" = "INSTALL" ]
  base=$(basename "$tgz")
  echo "$base" | grep -qi 'aarch64'
  if [ -n "$sha" ]; then
    got=$(sha256sum "$tgz" | awk '{print $1}')
    if [ "$got" != "$sha" ]; then
      echo "sha mismatch" >&2
      return 1
    fi
  fi
  tmpdir=$(mktemp -d "$M2/.tmp-XXXXXX")
  tar -xzf "$tgz" -C "$tmpdir"
  src=$(find "$tmpdir" -type f -name bitcoind | head -1 | xargs dirname)
  # shellcheck disable=SC1091
  . "$TMP/elf.sh"
  is_aarch64_elf "$src/bitcoind"
  ver=$(echo "$base" | sed -n 's/.*bitcoin-\([0-9][0-9.]*\).*/v\1/p' | head -1)
  rm -rf "$BINROOT/${impl}.prev"
  mkdir -p "$BINROOT/${impl}.prev"
  cp -a "$BINROOT/$impl/." "$BINROOT/${impl}.prev/"
  mkdir -p "$BINROOT/$impl/bin"
  cp -a "$src/bitcoind" "$src/bitcoin-cli" "$BINROOT/$impl/bin/"
  chmod 755 "$BINROOT/$impl/bin/"*
  printf '%s\n' "$ver" >"$BINROOT/$impl/VERSION"
  rm -rf "$tmpdir"
  echo "installed $impl $ver"
}

rollback_one() {
  impl=$1
  confirm=$2
  [ "$confirm" = "ROLLBACK" ]
  [ -x "$BINROOT/${impl}.prev/bin/bitcoind" ]
  stage="$BINROOT/${impl}.rollback-stage"
  rm -rf "$stage"
  mkdir -p "$stage"
  cp -a "$BINROOT/$impl/." "$stage/"
  rm -rf "$BINROOT/$impl"
  mkdir -p "$BINROOT/$impl"
  cp -a "$BINROOT/${impl}.prev/." "$BINROOT/$impl/"
  rm -rf "$BINROOT/${impl}.prev"
  mkdir -p "$BINROOT/${impl}.prev"
  cp -a "$stage/." "$BINROOT/${impl}.prev/"
  rm -rf "$stage"
  echo "rolled_back $impl $(cat "$BINROOT/$impl/VERSION")"
}

install_one core "$TGZ" "$SHA" INSTALL | grep -q 'installed core v29.4'
test -x "$BINROOT/core/bin/bitcoind"
grep -q 'v-old' "$BINROOT/core.prev/VERSION"
grep -q 'v29.4' "$BINROOT/core/VERSION"

rollback_one core ROLLBACK | grep -q 'rolled_back core v-old'
grep -q 'v-old' "$BINROOT/core/VERSION"
grep -q 'v29.4' "$BINROOT/core.prev/VERSION"

if install_one core "$TGZ" "deadbeef" INSTALL 2>/dev/null; then
  echo "FAIL: bad sha accepted"
  exit 1
fi

# UI stubs present
grep -q 'data-u11="install"' "$ROOT/files/www/knots/node.html"
grep -q 'action=install' "$ROOT/files/www/knots/node.js"
grep -q 'install)' "$ROOT/files/usr/libexec/knots/node-impl-api.sh"
grep -q 'client_max_body_size 120m' "$ROOT/files/etc/nginx/conf.d/knots-ui.conf"

# --- C3 regression: CGI-shaped staging + REAL node-impl.sh install-from ----
# The upload path stages under the sanitized ORIGINAL filename (&name= query
# param) so the aarch64 basename gate in node-impl.sh sees the real name —
# pre-C3 the staged name was a stub and every UI upload install failed.
API="$ROOT/files/usr/libexec/knots/node-impl-api.sh"

# Grep-level: sanitizing block + staging under the original name (fixed strings)
grep -qF 'NAME=$(urldecode "$(qval name)")' "$API"
grep -qF 'NAME=${NAME##*/}' "$API"
grep -qF "tr -cd 'A-Za-z0-9._-'" "$API"
grep -q 'bad_filename' "$API"
grep -qF 'tgz="$uploaddir/$NAME"' "$API"
echo "OK: CGI stages upload under sanitized original filename"

# Execution-level: run the REAL node-impl.sh install-from against a sandbox
# (base paths sed-rewritten like test-identity-regen.sh — no logic clone).
SB="$TMP/sb"
mkdir -p "$SB/libexec" "$SB/bin" "$SB/m2"
for f in node-impl.sh node-impl-lib.sh rpc.sh; do
	sed -e "s|/usr/libexec/knots|$SB/libexec|g" \
		-e "s|/mnt/bitcoin|$SB/m2|g" \
		-e "s|/srv/lxc|$SB/lxc|g" \
		-e "s|/etc/knots|$SB/etcknots|g" \
		-e "s|/tmp/knots|$SB/tmpknots|g" \
		"$ROOT/files/usr/libexec/knots/$f" >"$SB/libexec/$f"
done
# m2_mounted greps /proc/mounts; unprivileged userns is unavailable on dev/CI
# hosts, so point ONLY that check at a fixture mounts file.
sed -i "s| /proc/mounts| $SB/proc-mounts|g" "$SB/libexec/node-impl-lib.sh"
printf 'tmpfs %s tmpfs rw,relatime 0 0\n' "$SB/m2" >"$SB/proc-mounts"
chmod +x "$SB/libexec/node-impl.sh"
# Stubs: no syslog, no LXC on the host (lxc-attach fails → filename version label)
printf '#!/bin/sh\nexit 0\n' >"$SB/bin/logger"
printf '#!/bin/sh\nexit 1\n' >"$SB/bin/lxc-attach"
chmod +x "$SB/bin/logger" "$SB/bin/lxc-attach"

# Factory-seeded node-bin state (mirrors device after ensure_layout seeding).
# Active impl pinned to knots: since B15 made Core the default, an unconfigured
# device would read active=core and take the restart path (untestable without
# LXC); this fixture covers the supported no-restart install path.
mkdir -p "$SB/m2/node-bin/knots/bin" "$SB/m2/node-bin/core/bin"
make_aarch64_stub "$SB/m2/node-bin/knots/bin/bitcoind"
make_aarch64_stub "$SB/m2/node-bin/knots/bin/bitcoin-cli"
echo "v29.3.knots20260507" >"$SB/m2/node-bin/knots/VERSION"
make_aarch64_stub "$SB/m2/node-bin/core/bin/bitcoind"
make_aarch64_stub "$SB/m2/node-bin/core/bin/bitcoin-cli"
echo "v-old" >"$SB/m2/node-bin/core/VERSION"
echo knots >"$SB/m2/.node-impl"

# Stage exactly like the CGI does: body saved under the original filename
UP="$SB/m2/.node-uploads"
mkdir -p "$UP"
STAGED="$UP/bitcoin-29.4-aarch64-linux-gnu.tar.gz"
cp "$TGZ" "$STAGED"

if ! out=$(PATH="$SB/bin:$PATH" "$SB/libexec/node-impl.sh" \
		install-from core "$STAGED" "$SHA" INSTALL); then
	echo "FAIL: real install-from refused CGI-staged tarball: $out"; exit 1
fi
echo "$out" | grep -q 'installed core v29.4' || {
	echo "FAIL: real install-from output: $out"; exit 1
}
grep -qx 'v29.4' "$SB/m2/node-bin/core/VERSION"
grep -qx 'v-old' "$SB/m2/node-bin/core.prev/VERSION"
[ ! -e "$SB/tmpknots/node-busy" ] || { echo "FAIL: busy flag left behind"; exit 1; }

# The staged name is what passes the gate: a stub staging name must refuse
cp "$TGZ" "$UP/core-123.tar.gz"
if PATH="$SB/bin:$PATH" "$SB/libexec/node-impl.sh" \
		install-from core "$UP/core-123.tar.gz" "" INSTALL 2>"$TMP/refuse.err"; then
	echo "FAIL: stub-named tarball accepted"; exit 1
fi
grep -q 'aarch64' "$TMP/refuse.err"
echo "OK: real node-impl.sh install-from via CGI-shaped staging"

# --- X7 (review 2026-10-11): the Core-DEFAULT path (fresh unit: no impl
# recorded on M.2 or in /etc). status must report active core, and installing
# the inactive implementation (knots) must take the no-restart path.
rm -f "$SB/m2/.node-impl" "$SB/etcknots/node-impl"
st=$(PATH="$SB/bin:$PATH" "$SB/libexec/node-impl.sh" status)
printf '%s' "$st" | grep -q '"active":"core"' || { echo "FAIL: no recorded impl must read active=core: $st"; exit 1; }
STAGED_K="$UP/bitcoin-29.3.knots20260507-aarch64-linux-gnu.tar.gz"
cp "$TGZ" "$STAGED_K"
if ! out=$(PATH="$SB/bin:$PATH" "$SB/libexec/node-impl.sh" \
		install-from knots "$STAGED_K" "$SHA" INSTALL); then
	echo "FAIL: install of the inactive impl under the Core default refused: $out"; exit 1
fi
echo "$out" | grep -q 'installed knots' || { echo "FAIL: knots install output: $out"; exit 1; }
grep -qx 'v29.3.knots20260507' "$SB/m2/node-bin/knots/VERSION" \
	|| { echo "FAIL: knots version label from file name: $(cat "$SB/m2/node-bin/knots/VERSION")"; exit 1; }
[ ! -e "$SB/m2/.node-impl" ] || [ "$(cat "$SB/m2/.node-impl")" = core ] \
	|| { echo "FAIL: installing knots must not switch the active impl"; exit 1; }
echo "OK: Core default — status active=core, inactive knots install without switching"

echo "PASS: node-bin install-from + rollback + sha256 + U11 wiring"
