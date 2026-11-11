#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-CONF-UPGRADE-KEEP — 25.0.32.0 bug (user guide review, 2026-11-10): the
# user's node settings (Settings → Bitcoin node configuration) went back to
# the defaults on a keep-settings firmware upgrade (bitcoin.conf was not
# kept). Now keep.d keeps it and image-sync.sh rebuilds it from the new
# image's file with the user's own settings applied:
#  - user values (allowlisted and other non-protected keys) survive, once each
#  - protected keys always come from the NEW image (even if the kept file
#    differs) and the product keys check passes
#  - new defaults the image adds appear; merging again changes nothing
#  - a broken kept file falls back to the image's file
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
K="$ROOT/files/usr/libexec/knots"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT

for f in /srv/lxc/knots/rootfs/etc/bitcoin/bitcoin.conf /etc/knots/bitcoin.conf.image; do
	grep -qx "$f" "$ROOT/files/lib/upgrade/keep.d/knots" || fail "keep.d must keep $f"
done
awk '/^image_sync_from_rom\(\)/,/^}/' "$K/image-sync.sh" | awk '!c && /cp -a \/rom\/usr\/libexec\/knots\/\. /{c=NR} /image_sync_bitcoin_conf/{m=NR} END{exit !(c && m && c < m)}' \
	|| fail "image-sync must merge bitcoin.conf after copying the new helpers"
pass "keep.d keeps bitcoin.conf; image-sync merges it on the first boot of the new image"

# new image: one default changed, one new default, one protected value changed
sed -e 's/^maxconnections=125$/maxconnections=100/' -e 's#^rpcallowip=21.21.21.0/24$#rpcallowip=21.21.21.0/25#' \
	"$ROOT/lxc/bitcoin.conf" >"$W/rom.conf"
echo 'blockfilterindex=0' >>"$W/rom.conf"
grep -q '^maxconnections=100$' "$W/rom.conf" && grep -q '^rpcallowip=21.21.21.0/25$' "$W/rom.conf" || fail "test setup"
# kept file: old image + the user's changes (and a protected key that must not win)
{ sed -e 's/^dbcache=1024$/dbcache=2048/' -e 's/^maxconnections=125$/maxconnections=40/' "$ROOT/lxc/bitcoin.conf"
  printf '# my peers\naddnode=203.0.113.7\nmaxmempool=500\n'; } >"$W/kept.conf"
sed -i 's/^prune=0$/prune=550/' "$W/kept.conf"

merge() { sh -c ". '$K/bitcoin-conf-lib.sh'; conf_upgrade_merge '$1' '$2' '${3:-}'"; }
cp "$ROOT/lxc/bitcoin.conf" "$W/old-image.conf"          # the image the router came from
merge "$W/rom.conf" "$W/kept.conf" "$W/old-image.conf" >"$W/out.conf"
one() { [ "$(grep -c "^$1\$" "$W/out.conf")" = 1 ] || fail "expected exactly one '$1' in: $(cat "$W/out.conf")"; }
none() { grep -q "^$1" "$W/out.conf" && fail "'$1' must not be in the merged file"; true; }
one 'dbcache=2048'; one 'maxconnections=40'; one 'maxmempool=500'; one 'addnode=203.0.113.7'
none 'dbcache=1024'; none 'maxconnections=100'; none 'maxconnections=125'
one 'blockfilterindex=0'; one 'rpcallowip=21.21.21.0/25'; one 'prune=0'; none 'prune=550'
none 'rpcallowip=21.21.21.0/24'
sh -c ". '$K/bitcoin-conf-lib.sh'; conf_assert_product_keys '$W/out.conf'" || fail "merged file must pass the product keys check"
[ "$(sh -c ". '$K/bitcoin-conf-lib.sh'; conf_norm_protected '$W/out.conf'")" = \
  "$(sh -c ". '$K/bitcoin-conf-lib.sh'; conf_norm_protected '$W/rom.conf'")" ] || fail "protected keys must equal the new image's"
merge "$W/rom.conf" "$W/out.conf" "$W/rom.conf" >"$W/again.conf"
cmp -s "$W/out.conf" "$W/again.conf" || fail "merging twice must not change the file: $(diff "$W/out.conf" "$W/again.conf")"
# a default the user never touched follows the new image (natpmp untouched, image changes it)
sed 's/^natpmp=0$/natpmp=1/' "$W/rom.conf" >"$W/rom2.conf"
merge "$W/rom2.conf" "$W/out.conf" "$W/rom.conf" >"$W/next.conf"
[ "$(grep -c '^natpmp=1$' "$W/next.conf")" = 1 ] && ! grep -q '^natpmp=0$' "$W/next.conf" \
	|| fail "an untouched default must follow the new image: $(cat "$W/next.conf")"
grep -q '^dbcache=2048$' "$W/next.conf" || fail "user value lost on the second upgrade"
pass "user settings kept once each; protected keys and new defaults from the new image; untouched defaults follow the image; merge is stable"

# image_sync_bitcoin_conf end to end (paths overridden): merged in place; unchanged when equal
run_sync() { ROM_CONF="$W/rom.conf" CUR_CONF="$1" IMG_CONF="$W/img.conf" KNOTS_LIBEXEC="$K" PATH="$W/bin:$PATH" \
	sh -c ". '$K/image-sync.sh'; image_sync_bitcoin_conf"; }
mkdir -p "$W/bin"; printf '#!/bin/sh\nexit 0\n' >"$W/bin/logger"; chmod +x "$W/bin/logger"
cp "$W/kept.conf" "$W/cur.conf"; cp "$W/old-image.conf" "$W/img.conf"; run_sync "$W/cur.conf"
cmp -s "$W/cur.conf" "$W/out.conf" || fail "image_sync_bitcoin_conf must write the merged file"
cmp -s "$W/img.conf" "$W/rom.conf" || fail "the image's own file must be recorded for the next upgrade"
cp "$W/rom.conf" "$W/same.conf"; run_sync "$W/same.conf"; cmp -s "$W/same.conf" "$W/rom.conf" || fail "unchanged file must stay"
# a kept file that loses a product key in the merge → image file used
printf 'datadir=/somewhere/else\n' >"$W/rom-broken.conf"
cp "$W/kept.conf" "$W/cur2.conf"
ROM_CONF="$W/rom-broken.conf" CUR_CONF="$W/cur2.conf" IMG_CONF="$W/img2.conf" KNOTS_LIBEXEC="$K" PATH="$W/bin:$PATH" \
	sh -c ". '$K/image-sync.sh'; image_sync_bitcoin_conf"
cmp -s "$W/cur2.conf" "$W/rom-broken.conf" || fail "failed merge must fall back to the image's file"
pass "first boot after upgrade: merged in place; equal file untouched; failed merge falls back to the image"
echo "ALL PASS: test-conf-upgrade-keep (T-CONF-UPGRADE-KEEP)"
