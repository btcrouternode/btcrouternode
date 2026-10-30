#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-PHASE8 — review Phase 8 (2026-10-11): tests, supply chain, docs, minor.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
F="$ROOT/files"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# X1 — no host test depends on gitignored build output
grep -q 'files/srv/lxc/knots/rootfs' "$ROOT/tests/host/test-node-impl-persist.sh" \
	&& fail "X1: test-node-impl-persist reads the gitignored staged rootfs"
grep -q '^test -f "$ROOT/files/etc/knots/build_number"' "$ROOT/tests/host/test-node-impl-persist.sh" \
	&& fail "X1: build_number is generated (gitignored)"
pass "X1 host tests use tracked sources only"

# X2 — serial device tests quote their echo markers
for f in smoke.sh test-ui.sh test-iue.sh test-iue-e2e.sh test-iue-client.sh test-iue-regression.sh; do
	grep -q 'def quote_markers' "$ROOT/tests/device/$f" && grep -q 'quote_markers(' "$ROOT/tests/device/$f" \
		|| fail "X2: $f must quote echo markers (serial echo made them always match)"
done
python3 -I -c '
import re
def quote_markers(s): return re.sub(r"\becho (\w)(\w+)", r"echo \1'"''"'\2", s)
q = quote_markers("test -x f && echo NO_WIPE_OK;echo T123X")
assert "NO_WIPE_OK" not in q and "T123X" not in q, q
' || fail "X2: quote_markers must hide markers from the echoed command"
pass "X2 serial echo can no longer satisfy marker checks"

# X3 — never accept 301
grep -rnE "\(30[12], *30[12]\)|301\" in out|code in \([^)]*301" "$ROOT/tests/device" \
	| grep -v 'req.get_method()' && fail "X3: tests must not accept 301 (F135)"
grep -q 'HTTP_UI:302' "$ROOT/tests/device/test-ui.sh" || fail "X3: landing check must expect 302 → HTTPS"
pass "X3 302-only redirects; HTTPS landing"

# X4 — device tests only with an explicit SERIAL=
grep -n 'ttyUSB0 \]' "$ROOT/Makefile" && fail "X4: Makefile must not auto-run device tests when /dev/ttyUSB0 exists"
grep -rn 'SERIAL:-/dev/ttyUSB0' "$ROOT/tests/device" && fail "X4: device scripts must require SERIAL"
pass "X4 device tests require explicit SERIAL="

# X5 — supply chain
grep -q '^DEBIAN_IMAGE := debian:bookworm@sha256:[0-9a-f]\{64\}$' "$ROOT/build/version.env" || fail "X5: base image pinned by digest"
grep -q -- '--privileged' "$ROOT/lxc/rootfs-build.sh" && fail "X5: no privileged binfmt container"
grep -rnE 'curl[^|]*\| *(ba)?sh' "$ROOT/lxc" "$ROOT/build" "$ROOT/Makefile" "$F/usr" 2>/dev/null && fail "X5: no curl | sh"
pass "X5 pinned base image, no privileged container, no curl|sh"

# X6 — no lab credentials
lab_pw="password""client"   # split so this file does not contain it
grep -rn "$lab_pw" "$ROOT/tests" "$ROOT/Makefile" "$ROOT/factory" "$F" && fail "X6: lab password committed"
pass "X6 no lab credentials in tests / Makefile"

# X8 — docs agree with code
grep -q 'select \*\*Bitcoin Core (default, B15)\*\*' "$ROOT/REQUIREMENTS.md" || fail "X8: U7 must say Core default"
grep -q '21.21.21.0/24' "$ROOT/REQUIREMENTS.md" || fail "X8: DMZ link is /24"
pass "X8 requirements match the build (Core default, DMZ /24 link)"

# X10
[ -f "$F/etc/hotplug.d/iface/95-knots-dmz" ] && [ ! -e "$F/etc/hotplug.d/net/95-knots-dmz" ] \
	|| fail "X10: DMZ veth hook must be an iface hotplug (net events never carry INTERFACE=dmz)"
awk '/^start\(\)/,/^}/' "$F/etc/init.d/knots" | awk '/^\t\(/{sub_=1} /while \[/{ if (!sub_) bad=1 } END{exit bad}' \
	|| fail "X10: init.d/knots must not wait for the M.2 in the foreground"
grep -q 'rnode-\[0-9\]' "$F/etc/hotplug.d/iface/95-knots-avahi" || fail "X10: avahi rename check must cover any -N suffix"
grep -rnE '\|\| *\\?$' "$F/etc/init.d" | grep -q 'restart' && fail "X10: restart || … && start precedence"
pass "X10 DMZ hook fires on ifup, boot not blocked, avahi rename handled"

# UI: the CA fingerprint (95 chars, no spaces) must wrap inside its card
grep -q 'id="caFingerprint"' "$F/www/knots/settings.html" && \
	grep -q 'class="mono fingerprint" id="caFingerprint"' "$F/www/knots/settings.html" \
	&& grep -q '^\.fingerprint {.*overflow-wrap: anywhere' "$F/www/knots/app.css" \
	|| fail "Settings CA fingerprint must wrap (overflowed its card)"
grep -q 'class="settings-action settings-action-wide"' "$F/www/knots/settings.html" \
	&& grep -q '^\.settings-action-wide { grid-column: 1 / -1; }' "$F/www/knots/app.css" \
	|| fail "Renew HTTPS certificate card must span both columns"
pass "Settings CA fingerprint wraps inside its card; Renew card spans both columns"

echo "ALL PASS: test-phase8 (T-PHASE8)"
