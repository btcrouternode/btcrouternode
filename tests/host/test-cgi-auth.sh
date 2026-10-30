#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-CGI-AUTH — review S5 (2026-10-10): router credentials never in the URL.
#  - require_auth_fields refuses user=/password= in QUERY_STRING
#  - raw-body actions authenticate via "Authorization: KnotsForm user=…&password=…"
#  - form-body credentials keep working
#  - UI JS never builds a URL containing user=/password=
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/files/usr/libexec/knots/cgi-lib.sh"
WWW="$ROOT/files/www/knots"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

FN=$(mktemp)
trap 'rm -f "$FN"' EXIT
awk '/^urldecode_soft\(\)/,/^}/; /^urldecode\(\)/,/^}/; /^auth_header_field\(\)/,/^}/; /^require_auth_fields\(\)/,/^}/' \
	"$LIB" >"$FN"
cat >>"$FN" <<'EOF'
fail_json() { echo "DENY:$1"; exit 0; }
require_lan_client() { return 0; }
verify_router_auth() { [ "$1" = root ] && [ "$2" = 'p&ss w%rd' ] && return 0; echo "DENY:auth_failed"; exit 0; }
qval() { echo "$QS" | tr '&' '\n' | sed -n "s/^${1}=//p" | head -1; }
EOF

run() { # QUERY_STRING QS AUTHORIZATION
	QUERY_STRING=$1 QS=$2 HTTP_AUTHORIZATION=$3 sh -c ". '$FN'; require_auth_fields; echo ALLOW"
}
PW_ENC='p%26ss+w%25rd'

[ "$(run "action=upgrade&user=root&password=$PW_ENC" "action=upgrade&user=root&password=$PW_ENC" '')" = DENY:creds_in_url ] \
	|| fail "credentials in URL must be refused"
[ "$(run "action=conf_save&advanced=1&user=root" "action=conf_save&advanced=1&user=root" '')" = DENY:creds_in_url ] \
	|| fail "user= in URL must be refused"
[ "$(run 'action=upgrade' 'action=upgrade' "KnotsForm user=root&password=$PW_ENC")" = ALLOW ] \
	|| fail "Authorization: KnotsForm must authenticate raw-body actions"
[ "$(run 'action=upgrade' 'action=upgrade' "KnotsForm user=root&password=wrong")" = DENY:auth_failed ] \
	|| fail "wrong header password must fail"
[ "$(run 'action=upgrade' 'action=upgrade' "Basic cm9vdDp4")" = DENY:auth_failed ] \
	|| fail "non-KnotsForm Authorization must be ignored"
[ "$(run 'action=reboot' "action=reboot&confirm=REBOOT&user=root&password=$PW_ENC" '')" = ALLOW ] \
	|| fail "form-body credentials must keep working"
pass "require_auth_fields: no creds in URL; KnotsForm header; form body"

# UI: no URL (fetch/xhr target) may carry credentials.
for js in settings.js node.js; do
	awk '/var q =/,/;$/' "$WWW/$js" | grep -q 'password=' \
		&& fail "$js builds a request URL containing password="
	grep -n 'q += authQuery' "$WWW/$js" && fail "$js appends credentials to a URL"
done
grep -q 'setRequestHeader("Authorization", knotsFormAuth' "$WWW/settings.js" \
	|| fail "upgrade upload must send credentials in Authorization"
grep -q 'Authorization: knotsFormAuth(user, pass)' "$WWW/settings.js" \
	|| fail "advanced conf save must send credentials in Authorization"
grep -q 'Authorization: "KnotsForm"' "$WWW/node.js" \
	|| fail "node install must send credentials in Authorization"
pass "UI sends raw-body credentials in Authorization, never the URL"

# --- S8: session destroyed after the check; global failure lockout ---
S8=$(mktemp -d)
mkdir -p "$S8/bin"
cat >"$S8/bin/ubus" <<'EOF'
#!/bin/sh
echo "$*" >>"$UBUS_LOG"
# ubus call session login '<json>'  →  $1=call $2=session $3=login $4=json
case "$3" in
	login)
		case "$4" in
			*'"password":"right"'*)
				printf '{\n\t"ubus_rpc_session": "0123456789abcdef0123456789abcdef",\n\t"timeout": 300\n}\n' ;;
			*) exit 1 ;;
		esac ;;
esac
EOF
chmod +x "$S8/bin/ubus"
awk '/^auth_recent_failures\(\)/,/^}/; /^auth_note_failure\(\)/,/^}/; /^verify_router_auth\(\)/,/^}/' "$LIB" >"$S8/fn.sh"
va() { # PASS → Y / N / L(ocked)
	PATH="$S8/bin:$PATH" UBUS_LOG="$S8/ubus.log" sh -c "
		AUTH_FAIL_FILE='$S8/fails'; AUTH_FAIL_MAX=3; AUTH_FAIL_WINDOW=3
		sleep() { :; }
		. '$S8/fn.sh'
		AUTH_LOCKED=
		if verify_router_auth root \"\$1\"; then echo Y; elif [ -n \"\$AUTH_LOCKED\" ]; then echo L; else echo N; fi" _ "$1"
}
[ "$(va right)" = Y ] || fail "S8 correct password"
grep -q 'session destroy {"ubus_rpc_session":"0123456789abcdef0123456789abcdef"}' "$S8/ubus.log" \
	|| fail "S8 login session must be destroyed after the check"
[ "$(va wrong)" = N ] && [ "$(va wrong)" = N ] && [ "$(va wrong)" = N ] || fail "S8 wrong password"
[ "$(va right)" = L ] || fail "S8 after 3 failures even the right password must be locked out"
logins=$(grep -c 'session login' "$S8/ubus.log")
[ "$(va wrong)" = L ] && [ "$(grep -c 'session login' "$S8/ubus.log")" = "$logins" ] \
	|| fail "S8 locked-out attempts must not reach ubus"
command sleep 4
[ "$(va right)" = Y ] || fail "S8 lockout must expire after the window"
rm -rf "$S8"
pass "S8 ubus session destroyed; global lockout after repeated failures, then expires"

echo "ALL PASS: test-cgi-auth (T-CGI-AUTH)"
