#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-SETUP-TZ — 25.0.32.0 bug (user guide review, 2026-11-10): a browser
# timezone missing from the Setup list silently became the FIRST entry
# (Australia/Sydney), which also set the Wi-Fi country. Now the listed zone
# with the same UTC offset right now is chosen (same region preferred), else
# UTC, and the page says so. Runs the real setup.js functions in Node.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
JS="$ROOT/files/www/knots/setup.js"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
grep -q 'tzSel.value = nearestZone(pre.zonename, listed)' "$JS" || fail "unlisted browser zone must go through nearestZone"
grep -q 'id="choiceLocaleNote"' "$ROOT/files/www/knots/setup.html" || fail "Choice page needs the timezone note"
grep -q 'setup.locale.tz_nearest' "$JS" || fail "note must use setup.locale.tz_nearest"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed (static checks passed)"; exit 0; }
node - "$JS" "$ROOT/files/www/knots/i18n/regions.json" <<'JSEOF' || fail "nearestZone behaviour (see above)"
const fs = require("fs");
const src = fs.readFileSync(process.argv[2], "utf8");
const pick = (name) => { const a = src.indexOf("  function " + name + "("); let d = 0, i = src.indexOf("{", a);
  for (; i < src.length; i++) { if (src[i] === "{") d++; else if (src[i] === "}" && --d === 0) break; }
  return src.slice(a, i + 1); };
const nearestZone = new Function(pick("zoneOffsetMin") + "\n" + pick("nearestZone") + "\nreturn nearestZone;")();
const offset = new Function(pick("zoneOffsetMin") + "\nreturn zoneOffsetMin;")();
const zones = JSON.parse(fs.readFileSync(process.argv[3], "utf8")).regions.map(r => r.zonename);
let bad = 0;
const check = (zone, test, why) => { const got = nearestZone(zone, zones);
  if (!test(got)) { console.error(`${zone} → ${got}: ${why}`); bad++; } else console.log(`${zone} → ${got}`); };
for (const z of ["Europe/Belgrade", "Europe/Prague", "America/Bogota", "Asia/Karachi", "Africa/Nairobi", "Australia/Hobart"]) {
  check(z, g => g === "UTC" ? !zones.some(x => offset(x) === offset(z)) : offset(g) === offset(z) && g !== "Australia/Sydney" || z === "Australia/Hobart",
        "must have the same UTC offset now (or UTC when no listed zone has it)");
}
check("Europe/Belgrade", g => g.startsWith("Europe/"), "same region preferred");
check("Asia/Kathmandu", g => g === "UTC", "+5:45 is not listed → UTC, never the first entry");
check("Not/AZone", g => g !== "Australia/Sydney" || offset("Australia/Sydney") === -new Date().getTimezoneOffset(), "unknown zone → by this computer's offset");
process.exit(bad ? 1 : 0);
JSEOF
pass "unlisted browser timezone → listed zone with the same offset (same region first), else UTC; page says so"
echo "ALL PASS: test-setup-timezone (T-SETUP-TZ)"
