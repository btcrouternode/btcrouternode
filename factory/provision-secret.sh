#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Provision the per-device factory secret (review P1 / decision D1).
#
#   secret = HMAC-SHA256(factory key, ethaddr)  →  xxxx-xxxx-xxxx
#            (31-symbol alphabet without 0 1 i l o; must match the firmware's
#             knots_secret_valid in files/usr/libexec/knots/setup-lib.sh)
#
# Writes it to the unit's U-Boot env (fw_setenv knots_secret …, eMMC
# mmcblk0p1 'ubootenv' — survives factory reset and sysupgrade -n), verifies
# it, and on an unconfigured unit applies it at once (root password + default
# Wi-Fi rnode). Prints the label line and appends it to the label CSV.
#
# The FACTORY KEY never leaves the factory PC: it is read from a file, never
# printed, never put on a command line, never sent to the router. Only the
# derived per-unit secret is sent (over ssh stdin).
#
# Usage: factory/provision-secret.sh [--force] [--no-apply]
# Env:   KNOTS_FACTORY_KEY_FILE   key file (required; ≥32 bytes; mode 600/400)
#        ROUTER_SSH=root@192.168.1.254   SSH_OPTS="…extra ssh options…"
#        KNOTS_LABELS_CSV=~/knots-factory/labels.csv   (inventory, no passwords;
#        keep it out of git anyway — factory/labels*.csv is gitignored)
# Generate a factory key ONCE and keep it safe (backup offline):
#   umask 077; head -c 32 /dev/urandom > ~/knots-factory/factory.key
# pipefail: remote reads below are wrapped in `{ … || true; }` so a failed
# read reaches the explicit checks (with a message) instead of a silent exit.
set -euo pipefail

FORCE=0
APPLY=1
while [ $# -gt 0 ]; do
	case "$1" in
		--force) FORCE=1 ;;
		--no-apply) APPLY=0 ;;
		-h|--help) sed -n '2,27p' "$0"; exit 0 ;;
		*) echo "unknown arg: $1" >&2; exit 2 ;;
	esac
	shift
done

ROUTER_SSH="${ROUTER_SSH:-root@192.168.1.254}"
KEY_FILE="${KNOTS_FACTORY_KEY_FILE:-}"
LABELS="${KNOTS_LABELS_CSV:-$HOME/knots-factory/labels.csv}"

die() { echo "ABORT: $*" >&2; exit 1; }

[ -n "$KEY_FILE" ] || die "KNOTS_FACTORY_KEY_FILE not set (see --help to generate a key)"
[ -f "$KEY_FILE" ] || die "factory key file not found: $KEY_FILE"
mode=$(stat -c %a "$KEY_FILE" 2>/dev/null || stat -f %Lp "$KEY_FILE")
case "$mode" in
	600|400) ;;
	*) die "factory key $KEY_FILE has mode $mode — must be 600 or 400 (chmod 600)" ;;
esac
[ "$(wc -c <"$KEY_FILE" | tr -d ' ')" -ge 32 ] || die "factory key must be at least 32 bytes"

# shellcheck disable=SC2086
rssh() { ssh ${SSH_OPTS:-} "$ROUTER_SSH" "$@"; }

mac=$({ rssh 'fw_printenv -n ethaddr 2>/dev/null' || true; } | tr -d '\r\n' | tr 'A-F' 'a-f')
printf '%s' "$mac" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$' \
	|| die "could not read a valid ethaddr from the unit's U-Boot env (got '$mac')"

secret=$(python3 -I - "$KEY_FILE" "$mac" <<'PY'
import hashlib, hmac, sys
key = open(sys.argv[1], "rb").read()
mac = sys.argv[2].strip().lower().encode()
n = int.from_bytes(hmac.new(key, mac, hashlib.sha256).digest(), "big")
alphabet = "abcdefghjkmnpqrstuvwxyz23456789"   # 31 symbols: no 0 1 i l o
chars = []
for _ in range(12):
    n, r = divmod(n, len(alphabet))
    chars.append(alphabet[r])
s = "".join(chars)
print(f"{s[0:4]}-{s[4:8]}-{s[8:12]}")
PY
)
printf '%s' "$secret" | grep -Eq '^[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}-[a-hjkmnp-z2-9]{4}$' \
	|| die "internal: derived secret has an unexpected format"

existing=$({ rssh 'fw_printenv -n knots_secret 2>/dev/null' || true; } | tr -d '\r\n')
if [ -n "$existing" ] && [ "$existing" != "$secret" ] && [ "$FORCE" != 1 ]; then
	die "unit already has a DIFFERENT knots_secret (label mismatch risk). Re-run with --force only if you are relabelling this unit."
fi

if [ "$existing" != "$secret" ]; then
	# Secret over stdin, not argv (keeps it out of the router's process list).
	printf '%s\n' "$secret" | rssh 'read -r s; fw_setenv knots_secret "$s"' \
		|| die "fw_setenv failed"
fi
got=$({ rssh 'fw_printenv -n knots_secret 2>/dev/null' || true; } | tr -d '\r\n')
[ "$got" = "$secret" ] || die "verification failed: U-Boot env does not hold the derived secret"

applied=no
if [ "$APPLY" = 1 ]; then
	# Only on an unconfigured unit — never overwrite an owner's passwords.
	state=$(rssh '[ -f /etc/knots/setup-complete ] || [ -f /etc/knots/setup-password-done ] && echo configured || echo fresh')
	if [ "$state" = fresh ]; then
		rssh '. /usr/libexec/knots/setup-lib.sh; knots_factory_secret >/dev/null &&
			/usr/libexec/knots/factory/apply-password.sh &&
			rm -f /etc/knots/wifi-default-done &&
			/usr/libexec/knots/wifi-default-enable.sh' >/dev/null \
			|| die "secret stored but applying it (root password / Wi-Fi) failed"
		applied=yes
	fi
fi

ver=$({ rssh 'cat /etc/knots/product_version 2>/dev/null' || true; } | tr -d '\r\n')
mkdir -p "$(dirname "$LABELS")"
# Inventory line, NO password (owner, 2026-10-25): it is recalculated from the
# factory key whenever needed (factory/recover-sticker.py). Same writer as the
# station, which also removes an old password column.
python3 -I - "$LABELS" "$mac" "rnode-$(echo "$mac" | tr -d : | tail -c 5)" "$ver" "$KEY_FILE" \
	"$(dirname "$0")/label-batch.py" <<'PY' || die "could not append the inventory line"
import importlib.util, sys
labels, mac, unit, ver, key, mod = sys.argv[1:7]
spec = importlib.util.spec_from_file_location("label_batch", mod)
lb = importlib.util.module_from_spec(spec); spec.loader.exec_module(lb)
lb.migrate_inventory(labels, key)
lb.append_inventory(labels, mac, unit, "rnode", ver, lb.key_id(key))
PY

cat <<EOF

=== LABEL ===
  Wi-Fi name : rnode
  Password   : $secret        (router admin login: root / same password)
  Address    : http://rnode-$(echo "$mac" | tr -d : | tail -c 5).local/
  MAC        : $mac
=============
U-Boot env verified. Applied to root password + default Wi-Fi: $applied
Inventory line appended to $LABELS (no password — recalculated from the factory key)
EOF
