#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-NODE-REFRESH: a release that ships a newer factory node pin (Core 29.4 →
# 29.5, CVE-2026-117349) must reach routers already in use: at boot, before the
# node starts, an OLDER factory pin on the M.2 is replaced and kept as .prev for
# Rollback. Never while bitcoind runs, never an owner's own install or
# rollback, never Knots (pinned to the main-chain release). Runs the real
# node-impl.sh against a fake image rootfs and M.2.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

NI="$ROOT/files/usr/libexec/knots/node-impl.sh"
VE="$ROOT/build/version.env"

# Pins in the script = pins the image is built with.
kt=$(sed -n 's/^KNOTS_TAG := //p' "$VE"); ct=$(sed -n 's/^CORE_TAG := //p' "$VE")
grep -qx "FACTORY_KNOTS=$kt" "$NI" || fail "node-impl.sh FACTORY_KNOTS is not $kt (build/version.env)"
grep -qx "FACTORY_CORE=$ct" "$NI" || fail "node-impl.sh FACTORY_CORE is not $ct (build/version.env)"
! grep -q "^OLD_FACTORY_CORE=.*$ct" "$NI" || fail "the current Core pin must not be in OLD_FACTORY_CORE"
pass "factory pins match build/version.env ($kt, $ct)"

# The real script, with its libraries taken from the repository.
sed "s#/usr/libexec/knots/#$ROOT/files/usr/libexec/knots/#g" "$NI" >"$W/node-impl.sh"
mkdir -p "$W/path"
cat >"$W/path/pidof" <<'EOF'
#!/bin/sh
[ -f "$FAKE_RUNNING" ] && echo 4242 && exit 0
exit 1
EOF
cat >"$W/path/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$W/path/pidof" "$W/path/logger"
export PATH="$W/path:$PATH" FAKE_RUNNING="$W/running"
export NODE_IMPL_ROOTFS="$W/rootfs" NODE_IMPL_BINROOT="$W/m2/node-bin"

image() {	# the image's binaries, labelled with their version
	for impl in core knots; do
		mkdir -p "$W/rootfs/usr/local/lib/bitcoin/$impl/bin"
		for b in bitcoind bitcoin-cli; do
			printf '#!/bin/sh\necho %s %s\n' "$impl" "$1" >"$W/rootfs/usr/local/lib/bitcoin/$impl/bin/$b"
			chmod 755 "$W/rootfs/usr/local/lib/bitcoin/$impl/bin/$b"
		done
	done
}
m2() {	# m2 <impl> <version> [origin] — what is on the drive now
	d="$W/m2/node-bin/$1"; rm -rf "$d" "$d.prev"; mkdir -p "$d/bin"
	for b in bitcoind bitcoin-cli; do printf '#!/bin/sh\necho %s %s\n' "$1" "$2" >"$d/bin/$b"; chmod 755 "$d/bin/$b"; done
	echo "$2" >"$d/VERSION"
	[ -z "${3:-}" ] || echo "$3" >"$d/ORIGIN"
}
run() { sh "$W/node-impl.sh" refresh-factory >/dev/null 2>&1 || fail "refresh-factory failed"; }
ver() { cat "$W/m2/node-bin/$1/VERSION"; }

image new
m2 core v29.4; m2 knots "$kt"
run
[ "$(ver core)" = "$ct" ] || fail "Release 1 router: Core still $(ver core), want $ct"
grep -q "core new" "$W/m2/node-bin/core/bin/bitcoind" || fail "Core binary not replaced"
[ "$(cat "$W/m2/node-bin/core.prev/VERSION")" = v29.4 ] || fail "29.4 not kept for Rollback"
[ "$(cat "$W/m2/node-bin/core/ORIGIN")" = factory ] || fail "ORIGIN not factory"
[ "$(ver knots)" = "$kt" ] && grep -q "knots $kt" "$W/m2/node-bin/knots/bin/bitcoind" || fail "Knots must stay as it is"
pass "Release 1 router: Core v29.4 → $ct, 29.4 kept for Rollback, Knots untouched"

run
[ "$(cat "$W/m2/node-bin/core.prev/VERSION")" = v29.4 ] || fail "second boot changed .prev"
pass "second boot: nothing more to do"

m2 core v29.4; : >"$W/running"; run; rm -f "$W/running"
[ "$(ver core)" = v29.4 ] || fail "replaced Core while bitcoind was running"
pass "never while the node runs (next start)"

m2 core v29.4 owner; run
[ "$(ver core)" = v29.4 ] || fail "an owner's rollback to 29.4 was undone"
pass "an owner's rollback stays"

m2 core v30.0; run
[ "$(ver core)" = v30.0 ] || fail "an owner's own Core install was replaced"
pass "an owner's own install stays"

# knots-start: the refresh runs before the container starts.
KS="$ROOT/files/usr/libexec/knots/knots-start.sh"
a=$(grep -n 'node-impl.sh ensure-default' "$KS" | head -1 | cut -d: -f1)
b=$(grep -n 'lxc-start -n knots' "$KS" | head -1 | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "knots-start must run node-impl.sh ensure-default before lxc-start"
pass "knots-start refreshes before the node starts"
echo "ALL PASS: test-node-factory-refresh"
