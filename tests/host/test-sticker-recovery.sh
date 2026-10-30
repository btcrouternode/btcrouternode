#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# T-STICKER-RECOVERY (owner 2026-10-25): sticker passwords are never stored.
#  - an old labels.csv loses its password column once; key_id says which
#    factory key made each unit (checked against the stored password)
#  - recover-sticker.py: router name / 4 characters / MAC → the same password
#    (recalculated), a new sticker printed NOW, logged without the password
#  - a unit made with another factory key (TEST vs real) is refused
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
python3 -c 'import serial, PIL' 2>/dev/null || { echo "SKIP: pyserial / PIL"; exit 0; }
LB="$ROOT/factory/label-batch.py"
py() { python3 -I - "$LB" "$@"; }

head -c 32 /dev/urandom >"$W/factory-TEST.key"; head -c 32 /dev/urandom >"$W/other.key"; chmod 400 "$W"/*.key
derive() { py "$1" "$2" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("lb", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.derive_secret(sys.argv[2], sys.argv[3]))
PY
}
PW_A=$(derive "$W/factory-TEST.key" 3a:3f:64:1c:9e:3e)
PW_B=$(derive "$W/other.key" 3a:3f:64:1c:60:13)
printf '%s\n' "provisioned_utc,ethaddr,unit_name,wifi_ssid,password,product_version" \
	"2026-10-25T01:00:00Z,3a:3f:64:1c:9e:3e,rnode-9e3e,rnode,$PW_A,24.10.8.29.3.112" \
	"2026-10-25T02:00:00Z,3a:3f:64:1c:60:13,rnode-6013,rnode,$PW_B,24.10.8.29.3.112" >"$W/labels.csv"

# --- migration ---------------------------------------------------------------
py "$W/labels.csv" "$W/factory-TEST.key" <<'PY' || fail "migration"
import importlib.util, sys
s = importlib.util.spec_from_file_location("lb", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
assert m.migrate_inventory(sys.argv[2], sys.argv[3]) is True
assert m.migrate_inventory(sys.argv[2], sys.argv[3]) is False      # once only
PY
! grep -q "$PW_A\|$PW_B\|password" "$W/labels.csv" || fail "passwords must be gone: $(cat "$W/labels.csv")"
kid=$(python3 -c "import hashlib;print('TEST-'+hashlib.sha256(open('$W/factory-TEST.key','rb').read()).hexdigest()[:8])")
grep -q "^2026-10-25T01:00:00Z,3a:3f:64:1c:9e:3e,rnode-9e3e,rnode,24.10.8.29.3.112,$kid$" "$W/labels.csv" \
	&& grep -q "^2026-10-25T02:00:00Z,3a:3f:64:1c:60:13,rnode-6013,rnode,24.10.8.29.3.112,unknown$" "$W/labels.csv" \
	|| fail "key_id (this key / unknown): $(cat "$W/labels.csv")"
[ "$(stat -c %a "$W/labels.csv")" = 600 ] || fail "inventory stays 600"
pass "old labels.csv: password column removed once; key_id from this key, 'unknown' for another"

# --- recovery: name, 4 characters, MAC → same password, printed now ------------
export KNOTS_FACTORY_KEY_FILE="$W/factory-TEST.key" KNOTS_LABELS_CSV="$W/labels.csv"
PRINT="cp {png} $W/printed.png"
for q in rnode-9e3e 9e3e 3A:3F:64:1C:9E:3E; do
	rm -f "$W/printed.png"
	out=$(python3 -I "$ROOT/factory/recover-sticker.py" "$q" --out "$W/rec" --print-cmd "$PRINT" --reason "lost, test") \
		|| fail "recover $q: $out"
	echo "$out" | grep -q "^New sticker for rnode-9e3e (3a:3f:64:1c:9e:3e): $W/rec/.*-rnode-9e3e.png$" && echo "$out" | grep -qx "Printed." \
		&& [ -s "$W/printed.png" ] || fail "recover $q: $out"
done
py "$W/printed.png" "$W/factory-TEST.key" <<'PY' || fail "the printed sticker must be a 29 mm label PNG"
from PIL import Image
im = Image.open(__import__("sys").argv[2]); assert im.size == (1180, 306), im.size
PY
[ "$(derive "$W/factory-TEST.key" 3a:3f:64:1c:9e:3e)" = "$PW_A" ] || fail "recalculated password must equal the original"
R="$W/recoveries.csv"
[ "$(head -1 "$R")" = "recovered_utc,ethaddr,unit_name,key_id,reason,printed" ] && [ "$(grep -c ',3a:3f:64:1c:9e:3e,rnode-9e3e,' "$R")" = 3 ] \
	&& grep -q ",$kid,\"lost, test\",yes$" "$R" && ! grep -q "$PW_A" "$R" && [ "$(stat -c %a "$R")" = 600 ] \
	|| fail "recoveries.csv (logged, no password): $(cat "$R")"
out=$(python3 -I "$ROOT/factory/recover-sticker.py" 9e3e --out "$W/rec" --print-cmd "") || fail "dry run: $out"
echo "$out" | grep -q "No printer configured" && tail -1 "$R" | grep -q ',no$' || fail "no printer = PNG only, logged printed=no: $out"
pass "lost sticker: name / 4 characters / MAC → same password recalculated, new sticker printed now, logged without the password"

# --- refusals ------------------------------------------------------------------
out=$(python3 -I "$ROOT/factory/recover-sticker.py" rnode-6013 --out "$W/rec" --print-cmd "$PRINT" 2>&1) && fail "other key must be refused"
echo "$out" | grep -q "NOT RECOVERED: rnode-6013 was made with factory key unknown; this station has $kid" || fail "other key message: $out"
out=$(python3 -I "$ROOT/factory/recover-sticker.py" rnode-0000 --out "$W/rec" 2>&1) && fail "unknown router must be refused"
echo "$out" | grep -q "NOT RECOVERED: 'rnode-0000' is not in the inventory" || fail "unknown router message: $out"
out=$(KNOTS_FACTORY_KEY_FILE= python3 -I "$ROOT/factory/recover-sticker.py" 9e3e 2>&1) && fail "no key must stop"
echo "$out" | grep -q "no factory key" || fail "no key message: $out"
pass "refused: a router made with another factory key, an unknown router, no factory key"

# --- nothing writes passwords any more ---------------------------------------------
! grep -n '"password"' "$ROOT/factory/station/rnode_station.py" "$ROOT/factory/label-batch.py" | grep -v 'INVENTORY\|migrate\|"password" not in\|r.get("password")' \
	|| fail "factory code still writes a password column"
! grep -q 'wifi_ssid,password' "$ROOT/factory/provision-secret.sh" || fail "provision-secret.sh still writes passwords"
pass "station, sticker batch and SD-route provisioning write inventory lines without passwords"
echo "ALL PASS: test-sticker-recovery (T-STICKER-RECOVERY)"
