#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-RELEASE-SIG — signed releases (pre-production review, 2026-10-18).
# Throwaway keys only (generated in a temp dir, deleted on exit).
#  - factory/release-keygen.sh makes a usign pair; build/sign-release.sh signs
#    a published image in place (fwtool chunk) and refreshes its .sha256 line
#  - router side (release-sig.sh): with a key installed — signed+valid
#    accepted and stripped back to the exact signed bytes; tampered, wrong key
#    and unsigned refused. With no key installed (pre-production) — unsigned
#    and signed both proceed (trailer stripped).
#  - settings-api runs the check after the SHA256 match and records the hash
#    of the stripped image for upgrade-apply's re-verify.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
H="$ROOT/build/imagebuilder/staging_dir/host/bin"
LIB="$ROOT/files/usr/libexec/knots/release-sig.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
[ -x "$H/usign" ] && [ -x "$H/fwtool" ] || { echo "SKIP T-RELEASE-SIG: no Image Builder host usign/fwtool (make fetch-ib)"; exit 0; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# keygen
USIGN="$H/usign" sh "$ROOT/factory/release-keygen.sh" "$W/k" >"$W/kg.out"
fp=$(sed -n 's/.*PUBLIC fingerprint: //p' "$W/kg.out")
[ -n "$fp" ] && [ -f "$W/k/$fp" ] && [ -f "$W/k/rnode-release.sec" ] || fail "keygen output: $(cat "$W/kg.out")"
[ "$(stat -c %a "$W/k/rnode-release.sec")" = 600 ] || fail "secret key must be mode 600"
USIGN="$H/usign" sh "$ROOT/factory/release-keygen.sh" "$W/k" >/dev/null 2>&1 && fail "keygen must refuse to overwrite a secret key"
pass "release-keygen: usign pair, fingerprint-named public key, secret 600, no overwrite"

# offline tools stick (factory/make-keygen-usb.sh): runs without the Image
# Builder, labels A/B, copies only the public keys to the stick
mkdir -p "$W/stick"
sh "$ROOT/factory/make-keygen-usb.sh" "$W/stick" >"$W/mk.out" || fail "make-keygen-usb: $(cat "$W/mk.out")"
K="$W/stick/rnode-keygen"
( cd "$K" && sha256sum -c --quiet SHA256SUMS ) || fail "tools stick SHA256SUMS"
for L in A B; do
	env -i PATH=/usr/bin:/bin sh "$K/release-keygen.sh" "$W/key$L" "$L" "$K/public" >"$W/kg$L.out" \
		|| fail "offline keygen $L: $(cat "$W/kg$L.out")"
	grep -q 'self-test passed' "$W/kg$L.out" || fail "keygen $L self-test"
	head -1 "$W/key$L/rnode-release-$L.pub" | grep -q "RNode release key $L " || fail "key $L comment"
done
[ "$(ls "$K/public" | grep -cE '^[0-9a-f]{16}$')" = 2 ] || fail "two public keys on the tools stick"
find "$W/stick" -name '*.sec' | grep -q . && fail "a secret key reached the tools stick"
fpB=$(sed -n 's/.*PUBLIC fingerprint: //p' "$W/kgB.out")
cmp -s "$K/public/$fpB" "$W/keyB/rnode-release-B.pub" || fail "public key B copied intact"
[ -f "$K/sign-image.sh" ] && [ -f "$K/usign/bin/fwtool" ] || fail "tools stick carries sign-image.sh + fwtool"
head -c 5000 /dev/urandom >"$W/stick.itb"
env -i PATH=/usr/bin:/bin sh "$K/sign-image.sh" "$W/keyA/rnode-release-A.sec" "$W/stick.itb" >"$W/si.out" || fail "stick sign-image: $(cat "$W/si.out")"
grep -q "$(sha256sum "$W/stick.itb" | cut -c1-64)" "$W/si.out" || fail "sign-image prints the signed SHA256"
mkdir -p "$W/abkeys"; cp "$K/public/"* "$W/abkeys/"
st=$(KNOTS_RELEASE_KEYS="$W/abkeys" KNOTS_USIGN="$H/usign" KNOTS_FWTOOL="$H/fwtool" TMPDIR="$W" \
	sh -c ". '$LIB'; release_sig_check '$W/stick.itb'; echo \$RELEASE_SIG_STATE") ; [ "$st" = verified ] || fail "A-signed image vs A+B keys: $st"
pass "offline tools stick: self-contained usign + fwtool, keys A/B with self-test, only public keys on the stick, signs a release"

# a fake published build (version from version.env)
OV=$(sed -n 's/^OPENWRT_VER := //p' "$ROOT/build/version.env"); KV=$(sed -n 's/^CORE_VER := //p' "$ROOT/build/version.env")
BN=$(sed -n 's/^BUILD_NUM := //p' "$ROOT/build/version.env"); PRE="bpi-r4-phase2-$OV.$KV.$BN"
mkdir -p "$W/out"
head -c 300000 /dev/urandom >"$W/out/$PRE-squashfs-sysupgrade.itb"
# like real Image Builder output: already ends in OpenWrt's own build-key
# signature (a real .96 image does) — ours must go on top, not be refused
"$H/usign" -G -s "$W/ib.sec" -p "$W/ib.pub" -c ib >/dev/null
"$H/usign" -S -m "$W/out/$PRE-squashfs-sysupgrade.itb" -s "$W/ib.sec" -x "$W/ib.sig"
"$H/fwtool" -S "$W/ib.sig" "$W/out/$PRE-squashfs-sysupgrade.itb"
cp "$W/out/$PRE-squashfs-sysupgrade.itb" "$W/orig.itb"
( cd "$W/out"; sha256sum "$PRE-squashfs-sysupgrade.itb"; echo "0000  $PRE-sdcard.img.gz" ) >"$W/out/$PRE.sha256"
bash "$ROOT/build/sign-release.sh" "$W/k/rnode-release.sec" "$W/out" >"$W/sign.out" || fail "sign-release: $(cat "$W/sign.out")"
signed="$W/out/$PRE-squashfs-sysupgrade.itb"
cmp -s "$signed" "$W/orig.itb" && fail "image must carry the appended signature"
grep -q "$(sha256sum "$signed" | cut -c1-64)  $PRE-squashfs-sysupgrade.itb" "$W/out/$PRE.sha256" || fail ".sha256 must list the SIGNED image"
grep -q "$PRE-sdcard.img.gz" "$W/out/$PRE.sha256" || fail ".sha256 must keep the other lines"
bash "$ROOT/build/sign-release.sh" "$W/k/rnode-release.sec" "$W/out" >/dev/null 2>&1 && fail "signing twice must be refused"
pass "sign-release: signed over the build-key signature, .sha256 refreshed for the signed file, same key twice refused"

# router side
mkdir -p "$W/keys" "$W/nokeys"
cp "$W/k/$fp" "$W/keys/$fp"
check() { # KEYDIR IMAGE → prints state, returns rc
	KNOTS_RELEASE_KEYS="$1" KNOTS_USIGN="$H/usign" KNOTS_FWTOOL="$H/fwtool" TMPDIR="$W" \
		sh -c ". '$LIB'; release_sig_check '$2'; rc=\$?; echo \$RELEASE_SIG_STATE; exit \$rc"
}
cp "$signed" "$W/a.itb"
st=$(check "$W/keys" "$W/a.itb") || fail "valid signature refused ($st)"
[ "$st" = verified ] || fail "valid signature state: $st"
cmp -s "$W/a.itb" "$W/orig.itb" || fail "verified image must be stripped back to exactly the built image (build-key signature kept)"
cp "$signed" "$W/b.itb"; printf 'X' | dd of="$W/b.itb" bs=1 seek=4096 conv=notrunc 2>/dev/null
st=$(check "$W/keys" "$W/b.itb") && fail "tampered image accepted"
# fwtool's trailer CRC covers the whole file, so a modified image does not
# even yield its signature chunk (→ "unsigned"); refused either way, and a
# corrupted download is already stopped earlier by the pasted SHA256.
case "$st" in invalid|unsigned) ;; *) fail "tampered state: $st" ;; esac
USIGN="$H/usign" sh "$ROOT/factory/release-keygen.sh" "$W/k2" >"$W/kg2.out"
fp2=$(sed -n 's/.*PUBLIC fingerprint: //p' "$W/kg2.out"); mkdir -p "$W/keys2"; cp "$W/k2/$fp2" "$W/keys2/$fp2"
cp "$signed" "$W/c.itb"
st=$(check "$W/keys2" "$W/c.itb") && fail "image signed by another key accepted"
[ "$st" = invalid ] || fail "wrong-key state: $st"
cp "$W/orig.itb" "$W/d.itb"
st=$(check "$W/keys" "$W/d.itb") && fail "build signed only by the build key accepted while a release key is installed"
[ "$st" = invalid ] || fail "build-key-only state: $st"
head -c 4000 /dev/urandom >"$W/bare.itb"
st=$(check "$W/keys" "$W/bare.itb") && fail "unsigned image accepted while a release key is installed"
[ "$st" = unsigned ] || fail "unsigned state: $st"
pass "key installed: valid → verified + stripped; tampered / wrong key / unsigned → refused"

cp "$W/orig.itb" "$W/e.itb"
st=$(check "$W/nokeys" "$W/e.itb") || fail "pre-production (no key): unsigned must proceed"
[ "$st" = unchecked ] && cmp -s "$W/e.itb" "$W/orig.itb" || fail "pre-production: image must be left untouched ($st)"
cp "$signed" "$W/f.itb"
st=$(check "$W/nokeys" "$W/f.itb") || fail "pre-production: signed image must proceed"
cmp -s "$W/f.itb" "$signed" || fail "pre-production: signed image must be left untouched"
REAL=$(ls "$ROOT"/bin/targets/mediatek/filogic/bpi-r4-phase2-*-squashfs-sysupgrade.itb 2>/dev/null | tail -1 || true)
if [ -n "$REAL" ]; then
	cp "$REAL" "$W/r.itb"
	st=$(check "$W/keys" "$W/r.itb") && fail "a build signed only by OpenWrt's build key must not pass the release check"
	[ "$st" = invalid ] || [ "$st" = unsigned ] || fail "real unsigned build state: $st"
fi
pass "no key installed (pre-production): image untouched; Image Builder build-key signature never counts as a release signature"

# key staging (keys/ → overlay): test = A/B + TEST, release = A/B only
mkdir -p "$W/kd/release" "$W/kd/test" "$W/fs/etc/knots/release-keys"
cp "$W/keyA/$(ls "$W/keyA" | grep -E '^[0-9a-f]{16}$')" "$W/kd/release/"
cp "$W/keyB/$(ls "$W/keyB" | grep -E '^[0-9a-f]{16}$')" "$W/kd/release/"
cp "$W/k/$fp" "$W/kd/test/"
echo readme >"$W/fs/etc/knots/release-keys/README"; echo stale >"$W/fs/etc/knots/release-keys/0123456789abcdef"
KNOTS_KEYS_DIR="$W/kd" sh "$ROOT/build/stage-release-keys.sh" "$W/fs" test >/dev/null
[ "$(ls "$W/fs/etc/knots/release-keys" | grep -cE '^[0-9a-f]{16}$')" = 3 ] && [ -f "$W/fs/etc/knots/release-keys/$fp" ] \
	&& [ ! -e "$W/fs/etc/knots/release-keys/0123456789abcdef" ] && [ -f "$W/fs/etc/knots/release-keys/README" ] \
	&& [ "$(cat "$W/fs/etc/knots/build_channel")" = test ] || fail "test channel staging"
KNOTS_KEYS_DIR="$W/kd" sh "$ROOT/build/stage-release-keys.sh" "$W/fs" release >/dev/null
[ "$(ls "$W/fs/etc/knots/release-keys" | grep -cE '^[0-9a-f]{16}$')" = 2 ] && [ ! -e "$W/fs/etc/knots/release-keys/$fp" ] \
	&& [ "$(cat "$W/fs/etc/knots/build_channel")" = release ] || fail "release channel must carry A/B only (no test key)"
cp "$W/k/$fp" "$W/kd/release/BADNAME"
KNOTS_KEYS_DIR="$W/kd" sh "$ROOT/build/stage-release-keys.sh" "$W/fs" release >/dev/null 2>&1 && fail "bad key file name accepted"
rm -f "$W/kd/release/BADNAME"
# the real repository keys: A + B released, TEST separate, all valid public keys
[ "$(ls "$ROOT/keys/release" | grep -cE '^[0-9a-f]{16}$')" = 2 ] || fail "keys/release must hold exactly keys A and B"
for k in "$ROOT"/keys/test/*; do [ ! -e "$ROOT/keys/release/$(basename "$k")" ] || fail "test key in keys/release"; done
for k in "$ROOT"/keys/release/* "$ROOT"/keys/test/*; do
	[ "$("$H/usign" -F -p "$k")" = "$(basename "$k")" ] || fail "$k: file name is not its fingerprint"
done
git -C "$ROOT" ls-files files/etc/knots/release-keys | grep -qE '/[0-9a-f]{16}$' && fail "staged keys must not be tracked (generated from keys/)"
pass "key staging: test = A/B + TEST, release = A/B only, stale keys removed; repository keys named by fingerprint"

# releases kept next to the builds (Releases/<version>), never wiped by a build
T="$W/bt"; mkdir -p "$T/out/targets/mediatek/filogic/Releases/v1" "$T/ib/mediatek/filogic"
echo old >"$T/out/targets/mediatek/filogic/old.itb"; echo keep >"$T/out/targets/mediatek/filogic/Releases/v1/r.itb"
echo new >"$T/ib/mediatek/filogic/new.itb"
sh "$ROOT/build/refresh-targets.sh" "$T/ib" "$T/out"
[ -f "$T/out/targets/mediatek/filogic/new.itb" ] && [ ! -e "$T/out/targets/mediatek/filogic/old.itb" ] \
	&& [ "$(cat "$T/out/targets/mediatek/filogic/Releases/v1/r.itb")" = keep ] || fail "refresh-targets must replace builds and keep Releases"
grep -q 'refresh-targets.sh' "$ROOT/Makefile" && ! grep -q 'rm -rf $(OUT_DIR)/targets' "$ROOT/Makefile" || fail "make image must not wipe Releases"
pass "make image replaces the build output but keeps Releases/"

# store-release: only an A/B-signed RELEASE build of this version is filed
SD="$W/st"; mkdir -p "$SD/kd/release"; cp "$W/keyA/$(ls "$W/keyA" | grep -E '^[0-9a-f]{16}$')" "$SD/kd/release/"
mkdir -p "$SD/dir"; cp "$W/orig.itb" "$SD/dir/$PRE-squashfs-sysupgrade.itb"; echo sd >"$SD/dir/$PRE-sdcard.img.gz"
echo release >"$SD/channel"
st_run() { TARGETS_DIR="$SD/dir" KNOTS_KEYS_DIR="$SD/kd" BUILD_CHANNEL_FILE="$SD/channel" HOST_BIN="$H" sh "$ROOT/build/store-release.sh" "$1"; }
cp "$W/orig.itb" "$SD/a.itb"; HOST_BIN="$H" sh "$ROOT/factory/sign-image.sh" "$W/keyA/rnode-release-A.sec" "$SD/a.itb" >/dev/null
cp "$W/orig.itb" "$SD/t.itb"; HOST_BIN="$H" sh "$ROOT/factory/sign-image.sh" "$W/k/rnode-release.sec" "$SD/t.itb" >/dev/null
st_run "$SD/t.itb" >/dev/null 2>&1 && fail "store-release accepted a non-release (TEST) signature"
st_run "$W/orig.itb" >/dev/null 2>&1 && fail "store-release accepted an image without a release signature"
head -c 999 /dev/urandom >"$SD/other"; HOST_BIN="$H" sh "$ROOT/factory/sign-image.sh" "$W/keyA/rnode-release-A.sec" "$SD/other" >/dev/null
st_run "$SD/other" >/dev/null 2>&1 && fail "store-release accepted an A-signed file that is not this build"
echo test >"$SD/channel"; st_run "$SD/a.itb" >/dev/null 2>&1 && fail "store-release accepted a test-channel build"
echo release >"$SD/channel"
st_run "$SD/a.itb" >"$SD/out.txt" 2>&1 || fail "store-release refused a good A-signed release: $(cat "$SD/out.txt")"
R=$(ls -d "$SD/dir/Releases/"*)
cmp -s "$R/$PRE-squashfs-sysupgrade.itb" "$SD/a.itb" && [ -f "$R/$PRE-sdcard.img.gz" ] || fail "release files not stored"
grep -q "$(sha256sum "$SD/a.itb" | cut -c1-64)  $PRE-squashfs-sysupgrade.itb" "$R/$PRE.sha256" || fail "release .sha256 must list the signed image"
grep -q "^signed_by=$(ls "$SD/kd/release")$" "$R/RELEASE" || fail "RELEASE must record the signing key: $(cat "$R/RELEASE")"
[ ! -w "$R/$PRE-squashfs-sysupgrade.itb" ] || fail "stored release must be read-only"
st_run "$SD/a.itb" >/dev/null 2>&1 && fail "store-release overwrote an existing release"
chmod -R u+w "$SD/dir/Releases"
pass "store-release: A-signed release build filed read-only with SHA256 + signer; TEST / unsigned / other image / test channel / overwrite refused"

# wiring
S="$ROOT/files/usr/libexec/knots/settings-api.sh"
blk=$(awk '/^\tupgrade\)/,/^\t\t;;$/' "$S")
printf '%s\n' "$blk" | awk '/sha256_mismatch/{m=NR} /release_sig_check/{c=NR} /upgrade-pending/{p=NR} END{exit !(m && c && p && m < c && c < p)}' \
	|| fail "settings upgrade: SHA256 check → release_sig_check → pending record, in that order"
printf '%s\n' "$blk" | grep -q 'unsigned_image' && printf '%s\n' "$blk" | grep -q 'bad_signature' || fail "clear refusals for unsigned / bad signature"
ls "$ROOT/files/etc/knots/release-keys" | grep -qE '^[0-9a-f]{16}$' && \
	echo "NOTE: a release key is installed — Settings requires signed images"
git -C "$ROOT" ls-files | grep -qE '\.sec$' && fail "a secret key is tracked in git"
grep -q '^\*\.sec$' "$ROOT/.gitignore" || fail ".gitignore must exclude *.sec"
pass "settings-api order + refusals; no secret key tracked"
echo "ALL PASS: test-release-sig (T-RELEASE-SIG)"
