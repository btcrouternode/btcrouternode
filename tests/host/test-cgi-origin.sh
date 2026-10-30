#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-CGI-ORIGIN — review S3 (2026-10-10): backend CSRF gate.
#  - origin_is_appliance (cgi-lib.sh) accepts only the appliance's own names /
#    private IP literals and mirrors the nginx $knots_origin_ok map.
#  - require_mutating_post also enforces same-origin.
#  - setup-api.sh gates every non-read action with require_mutating_post.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/files/usr/libexec/knots/cgi-lib.sh"
API="$ROOT/files/usr/libexec/knots/setup-api.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# cgi-lib.sh sources the on-device rpc.sh; pull just the functions under test.
FN=$(mktemp)
trap 'rm -f "$FN"' EXIT
awk '/^origin_is_appliance\(\)/,/^}/; /^require_same_origin\(\)/,/^}/; /^require_mutating_post\(\)/,/^}/' \
	"$LIB" >"$FN"
cat >>"$FN" <<'EOF'
fail_json() { echo "DENY:$1"; exit 0; }
EOF

ok_origins='http://rnode.local https://rnode.local http://rnode.local:80 https://node-router
http://knots-router http://node-router.lan https://rnode-2.local http://192.168.1.254
http://10.0.0.1:8080 http://172.16.5.4 http://172.31.0.1 http://[fd00::1] https://[fe80::1]:443
http://localhost http://127.0.0.1'
bad_origins='null https://evil.example http://attacker.com http://rnode.local.evil.com
http://172.32.0.1 http://8.8.8.8 http://192.168.1.254.nip.io ftp://rnode.local
http://a.b.local http://user@rnode.local http://rnode.local/x http://bad_name.lan'

for o in $ok_origins; do
	out=$(sh -c ". '$FN'; origin_is_appliance '$o' && echo Y || echo N")
	[ "$out" = Y ] || fail "origin_is_appliance should accept $o"
done
for o in $bad_origins; do
	out=$(sh -c ". '$FN'; origin_is_appliance '$o' && echo Y || echo N")
	[ "$out" = N ] || fail "origin_is_appliance should reject $o"
done
pass "origin_is_appliance accepts appliance names/private IPs, rejects foreign/null"

run_gate() { # METHOD ORIGIN
	REQUEST_METHOD=$1 HTTP_ORIGIN=$2 sh -c ". '$FN'; require_mutating_post; echo ALLOW"
}
[ "$(run_gate GET '')" = "DENY:method" ] || fail "GET must be refused"
[ "$(run_gate POST '')" = "ALLOW" ] || fail "POST without Origin (curl/UAT) must pass"
[ "$(run_gate POST 'http://rnode.local')" = "ALLOW" ] || fail "same-origin POST must pass"
[ "$(run_gate POST 'https://evil.example')" = "DENY:origin_denied" ] || fail "foreign POST must be refused"
[ "$(run_gate POST 'null')" = "DENY:origin_denied" ] || fail "Origin: null must be refused"
pass "require_mutating_post = POST + same-origin"

# setup-api.sh: the gate must sit before the action dispatch and cover all
# non-read actions (status / wan_status are the only reads).
awk '/^setup_complete_check$/{f=1} f&&/^case "\$ACTION" in$/{n++} n==1&&f' "$API" \
	| grep -q 'status|wan_status) require_same_origin' \
	|| fail "setup-api.sh: read actions must use require_same_origin"
awk '/^setup_complete_check$/{f=1} f&&/^case "\$ACTION" in$/{n++} n==1&&f' "$API" \
	| grep -q '\*) require_mutating_post' \
	|| fail "setup-api.sh: all other actions must require_mutating_post"
first_gate=$(grep -n 'require_mutating_post ;;' "$API" | head -1 | cut -d: -f1)
first_action=$(grep -n '^	password)' "$API" | head -1 | cut -d: -f1)
[ "$first_gate" -lt "$first_action" ] || fail "setup-api.sh gate must run before action handlers"
pass "setup-api.sh gates every mutating action (POST + same-origin)"

echo "ALL PASS: test-cgi-origin (T-CGI-ORIGIN)"
