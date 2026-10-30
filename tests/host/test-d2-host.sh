#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-D2-HOST — review Phase 6 (2026-10-11).
#  H3/D2  every link / redirect keeps the host the browser used (rnode.local,
#         node-router, knots-router, or a private IPv4 = LAN IP) and falls back
#         to rnode.local; no hard-coded rnode.local URL outside that fallback.
#  H4     no cross-origin sessionStorage hand-off from Settings.
#  H6     one probe at a time in the TLS watch; stall timer cleared; one
#         visibility-aware wait-page poller; i18n served on :80 after Setup.
#  H7     one "where to go" builder (KnotsIue.destUrl).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WWW="$ROOT/files/www/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- no hard-coded rnode.local URLs in browser code (fallback literal only)
bad=$(grep -nE '"https?://rnode\.local|'"'"'https?://rnode\.local' "$WWW"/*.js \
	"$ROOT/files/www/luci-static/resources/knots-return.js" 2>/dev/null || true)
[ -z "$bad" ] || fail "hard-coded rnode.local URLs left:
$bad"
grep -n "return 302 https\?://rnode\.local" "$ROOT/files/etc/nginx/conf.d/knots-ui.conf" && fail "nginx redirect hard-codes rnode.local"
pass "H3: no hard-coded rnode.local URLs (JS, LuCI helper, nginx)"

# --- shell.js host rule (evaluated, not grepped)
if command -v node >/dev/null 2>&1; then
	node -e '
const fs = require("fs");
const src = fs.readFileSync(process.argv[1], "utf8");
const body = src.slice(src.indexOf("function hostIsAppliance"), src.indexOf("function luciUrl"));
const mk = new Function("location", "var hostOverride = \"\";\n" + body + "\nreturn {applianceHost, followLanIp};");
const cases = [["rnode.local","rnode.local"],["192.168.1.254","192.168.1.254"],["NODE-ROUTER","node-router"],
  ["10.1.2.3","10.1.2.3"],["172.31.0.1","172.31.0.1"],["172.32.0.1","rnode.local"],["8.8.8.8","rnode.local"],
  ["evil.example","rnode.local"],["rnode-3f2a.local","rnode-3f2a.local"],["rnode-2.local","rnode.local"],["printer.lan","rnode.local"],["",""+"rnode.local"]];
for (const [h, want] of cases) {
  const got = mk({hostname: h}).applianceHost();
  if (got !== want) { console.error("host " + h + " -> " + got + " want " + want); process.exit(1); }
}
let f = mk({hostname: "192.168.1.254"}); f.followLanIp("10.9.9.1");
if (f.applianceHost() !== "10.9.9.1") { console.error("IP host must follow LAN move"); process.exit(1); }
f = mk({hostname: "rnode.local"}); f.followLanIp("10.9.9.1");
if (f.applianceHost() !== "rnode.local") { console.error("name host must not follow LAN move"); process.exit(1); }
' "$WWW/shell.js" || fail "shell.js D2 host rule"
	# wait-handoff destinations follow KnotsIue.host
	node -e '
globalThis.KnotsIue = { host: () => "192.168.7.1" };
const wh = require(process.argv[1]);
const api = wh.decideDest ? wh : (globalThis.KnotsWaitHandoff || wh);
const d = api.decideDest("upgradeKeep", { setupComplete: true });
if (d.url !== "https://192.168.7.1/") { console.error("dest " + d.url); process.exit(1); }
const s = api.decideDest("reset", {});
if (s.url !== "http://192.168.7.1/setup.html?step=0") { console.error("setup dest " + s.url); process.exit(1); }
' "$WWW/wait-handoff.js" || fail "wait-handoff destinations must use the D2 host"
	pass "D2: shell.js host rule (names / private IPv4 / fallback, IP follows LAN move); wait-handoff follows it"
fi

# --- LuCI controller host logic on the image's own ucode (skip without it)
RFS="$ROOT/build/imagebuilder/build_dir/target-aarch64_cortex-a53_musl/root-mediatek"
if [ -x "$RFS/usr/bin/ucode" ] && command -v docker >/dev/null 2>&1 && [ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] \
	&& docker image inspect alpine:3.20 >/dev/null 2>&1; then
	W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
	{
		echo "let HOST; let http = { getenv: function(k) { return k == 'HTTP_HOST' ? HOST : null; } };"
		awk '/^function node_dashboard_url/,/^}/' "$ROOT/files/usr/share/ucode/luci/controller/admin/node_dashboard.uc"
		echo "for (let h in ['rnode.local', '192.168.1.254:8443', 'NODE-ROUTER', 'evil.com', '8.8.8.8', '[fe80::1]:8443', '', '172.20.1.1']) { HOST = h; print(h, ' = ', node_dashboard_url(), '\n'); }"
	} >"$W/t.uc"
	out=$(docker run --rm -v "$RFS":/rootfs:ro -v "$W":/rootfs/mnt alpine:3.20 chroot /rootfs /usr/bin/ucode /mnt/t.uc 2>&1) \
		|| fail "image ucode rejects node_dashboard.uc: $out"
	for want in 'rnode.local = https://rnode.local/' '192.168.1.254:8443 = https://192.168.1.254/' \
		'NODE-ROUTER = https://node-router/' 'evil.com = https://rnode.local/' '8.8.8.8 = https://rnode.local/' \
		'[fe80::1]:8443 = https://rnode.local/' ' = https://rnode.local/' '172.20.1.1 = https://172.20.1.1/'; do
		printf '%s\n' "$out" | grep -qxF "$want" || fail "ucode node_dashboard_url: missing '$want' in:
$out"
	done
	pass "LuCI exit redirect (image ucode): validated Host kept, everything else → rnode.local"
else
	echo "SKIP: LuCI ucode check (no image rootfs / docker / binfmt)"
fi
cmp -s "$ROOT/files/usr/share/ucode/luci/controller/admin/node_dashboard.uc" "$ROOT/files/etc/knots/overlay-ui/node_dashboard.uc" \
	&& cmp -s "$ROOT/files/usr/share/ucode/luci/template/themes/bootstrap/sysauth.ut" "$ROOT/files/etc/knots/overlay-ui/sysauth.ut" \
	&& cmp -s "$ROOT/files/usr/share/ucode/luci/template/node_dashboard.ut" "$ROOT/files/etc/knots/overlay-ui/node_dashboard.ut" \
	|| fail "overlay-ui copies must match the shipped LuCI files"

# --- H4 / H6 / H7 structure
grep -q 'sessionStorage.setItem' "$WWW/settings.js" && fail "H4: Settings must not write wait hand-off state"
awk '/function startTlsWatch/,/^  }$/' "$WWW/setup.js" | grep -q 'if (inFlight) return' || fail "H6: TLS watch must not overlap probes"
awk '/function tlsStalledText/,/^  }$/' "$WWW/setup.js" | grep -q 'return "";' && fail "H6: stall text must not be empty"
awk '/onFinish: function/,/clearUpgradeUi/' "$WWW/upgrade.js" | grep -q 'clearInterval(stallTimer)' || fail "H6: upgrade stall timer must stop on finish"
[ ! -f "$WWW/reset-watch.js" ] || fail "H7: reset-watch.js duplicated the shell.js poller"
grep -rq 'reset-watch' "$WWW"/*.html && fail "H7: pages must not load reset-watch.js"
awk '/listen 80 default_server/,/^}/' "$ROOT/files/etc/nginx/conf.d/knots-ui.conf" | awk '/location \/i18n\//,/}/' \
	| grep -q 'return 302' && fail "H6: :80 /i18n/ must not redirect after Setup"
for f in reset.js upgrade.js settings.js; do
	grep -q 'KnotsIue.destUrl' "$WWW/$f" || fail "H7: $f must use KnotsIue.destUrl"
done
pass "H4 no cross-origin hand-off; H6 timers/pollers/i18n; H7 one destination builder"

echo "ALL PASS: test-d2-host (T-D2-HOST)"
