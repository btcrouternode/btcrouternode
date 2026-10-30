#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# T-OFFLINE: the live-session script (owner 2026-10-27: no typing). With fake
# key sticks and the real tools: keys A + B land ON the sticks and work from
# there, only public halves come back; signing checks the tools / release
# fingerprints, refuses a key not built into the release, and verifies the
# signed release like the router does.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
[ -f "$ROOT/bin/offline-tools/rnode-keygen/rnode-offline.sh" ] || { echo "SKIP: make offline-tools"; exit 0; }
cmp -s "$ROOT/bin/offline-tools/rnode-keygen/rnode-offline.sh" "$ROOT/factory/offline/rnode-offline.sh" \
	&& cmp -s "$ROOT/bin/offline-tools/rnode-keygen/sign-release.sh" "$ROOT/factory/offline/sign-release.sh" \
	|| fail "bin/offline-tools is out of date (make offline-tools)"
sh "$ROOT/build/stage-offline.sh" keys >/dev/null || fail "stage keys"
cp -r "$ROOT/bin/offline-stage/rnode-sign" "$W/rnode-sign"; R="$W/rnode-sign"; K="$R/rnode-keygen"
mkdir -p "$W/stickA" "$W/stickB"; : >"$W/sticks"
cat >"$W/hook" <<H
#!/bin/sh
case "\$1" in
	*"Plug in KEY A"*) echo "$W/stickA" >"$W/sticks" ;;
	*"Plug in KEY B"*) echo "$W/stickB" >"$W/sticks" ;;
	*unplug*) : >"$W/sticks" ;;
esac
H
chmod +x "$W/hook"
export RNODE_OFFLINE_TEST=1 RNODE_OFFLINE_STICKS="$W/sticks" RNODE_OFFLINE_HOOK="$W/hook" RNODE_OFFLINE_TMP="$W/tmp"
U="$K/usign/bin/usign"

# --- 1) keys -------------------------------------------------------------------
printf 'y\n\ny\n\n\ny\n\n' | bash "$K/rnode-offline.sh" 1 >"$W/keys.out" 2>&1 || fail "keys: $(cat "$W/keys.out")"
for L in A B; do
	l=$(echo $L | tr AB ab); s="$W/stick$L/release-key/rnode-release-$L.sec"
	[ -s "$s" ] || fail "key $L must be ON stick $L: $(ls -R "$W/stick$L")"
	fp=$("$U" -F -s "$s"); [ -f "$R/new-public/$fp" ] || fail "public $L ($fp) not in new-public"
	grep -q "$fp" "$W/keys.out" || fail "fingerprint $L not shown"
done
[ "$(ls "$R/new-public" | wc -l)" = 2 ] || fail "new-public must hold exactly 2 public keys"
[ -z "$(find "$R" "$W/tmp" -name '*.sec')" ] || fail "a secret key outside the sticks"
grep -q "no secret key anywhere but the sticks" "$W/keys.out" || fail "keys run must end with the no-secret check"
pass "keys: A and B made ON the sticks, sign + verify from there, only public halves back, nothing secret left"

out=$(printf 'y\n\ny\n' | bash "$K/rnode-offline.sh" 1 2>&1) && fail "an existing key must never be overwritten"
echo "$out" | grep -q "already holds a key" || fail "overwrite refusal message: $out"
pass "keys: a stick that already holds a key is never overwritten"

# --- 2) sign -------------------------------------------------------------------
fpA=$("$U" -F -s "$W/stickA/release-key/rnode-release-A.sec")
head -c 300000 /dev/urandom >"$R/unsigned/fake.itb"
mkdir -p "$R/release-keys"; rm -f "$R/release-keys"/*; cp "$R/new-public"/* "$R/release-keys/"
tsha=$(cd "$K" && sha256sum SHA256SUMS | cut -d' ' -f1); rsha=$(sha256sum "$R/unsigned/fake.itb" | cut -d' ' -f1)
expected() { printf 'TOOLS_SHA256=%s\nRELEASE=fake.itb\nRELEASE_SHA256=%s\nRELEASE_KEYS="%s"\n' "$tsha" "$1" "$2" >"$R/EXPECTED"; }
expected "$rsha" "$(ls "$R/release-keys" | tr '\n' ' ' | sed 's/ $//')"
printf 'y\ny\n\ny\n\n' | bash "$K/rnode-offline.sh" 2 >"$W/sign.out" 2>&1 || fail "sign: $(cat "$W/sign.out")"
grep -q "signed with key $fpA and verified like the router does" "$W/sign.out" || fail "sign: $(cat "$W/sign.out")"
cp "$R/signed/fake.itb" "$W/v.itb"; "$K/usign/bin/fwtool" -q -t -s "$W/v.sig" "$W/v.itb" >/dev/null 2>&1 || true
"$U" -V -q -m "$W/v.itb" -P "$R/release-keys" -x "$W/v.sig" || fail "signed file must verify against the release keys"
cmp -s "$W/v.itb" "$R/unsigned/fake.itb" || fail "stripping the signature must give back the exact release"
grep -q "$(sha256sum "$R/signed/fake.itb" | cut -d' ' -f1)" "$W/sign.out" || fail "signed fingerprint must be shown"
pass "sign: tools + release checked, signed with key A, verified like the router, signed fingerprint shown"

# sign-release.sh (the one-line path): refuses while online, before any signing
rm -f "$R/signed/fake.itb"
out=$(printf 'y\ny\n\ny\n\n' | RNODE_OFFLINE_FAKE_ONLINE=1 bash "$K/sign-release.sh" 2>&1) && fail "sign-release must refuse while online"
echo "$out" | grep -q "this laptop is ONLINE" || fail "online message: $out"
[ ! -e "$R/signed/fake.itb" ] || fail "nothing may be signed while online"
printf 'y\ny\n\ny\n\n' | bash "$K/sign-release.sh" >"$W/sr.out" 2>&1 || fail "sign-release: $(cat "$W/sr.out")"
grep -q "Offline: no network connection" "$W/sr.out" && grep -q "signed with key $fpA and verified like the router does" "$W/sr.out" ||
	fail "sign-release: $(cat "$W/sr.out")"
cp "$R/signed/fake.itb" "$W/v2.itb"; "$K/usign/bin/fwtool" -q -t -s "$W/v2.sig" "$W/v2.itb" >/dev/null 2>&1 || true
"$U" -V -q -m "$W/v2.itb" -P "$R/release-keys" -x "$W/v2.sig" || fail "sign-release: signed file must verify"
grep -q "sign-release.sh" "$K/SHA256SUMS" || fail "sign-release.sh must be covered by the tools fingerprint"
grep -q 'sign-release.sh' "$ROOT/factory/offline/sign.sh" && grep -q 'factory/offline/sign.sh' "$ROOT/build/stage-offline.sh" ||
	fail "the staged folder needs sign.sh, which runs the fingerprinted sign-release.sh"
pass "sign-release: refuses online, signs offline like choice 2, covered by the tools fingerprint; sign.sh staged"

expected "$rsha" "0000000000000000"
out=$(printf 'y\ny\n\ny\n' | bash "$K/rnode-offline.sh" 2 2>&1) && fail "a key not built into the release must be refused"
echo "$out" | grep -q "is not one of the keys built into this release" || fail "wrong-key message: $out"
expected "$(printf '%064d' 0)" "$fpA"
out=$(printf 'y\n' | bash "$K/rnode-offline.sh" 2 2>&1) && fail "a changed release must be refused"
echo "$out" | grep -q "is not the one the build PC staged" || fail "changed-release message: $out"
echo tampered >>"$K/rnode-offline.sh"
out=$(printf 'y\n' | bash "$K/rnode-offline.sh" 2 2>&1) && fail "changed tools must be refused"
echo "$out" | grep -q "the tools do not match their own checksums" || fail "changed-tools message: $out"
pass "sign refuses: a key not built into the release, a changed release, changed tools (incl. this script)"
# --- 3) maintainer identity -----------------------------------------------------
command -v gpg >/dev/null || { echo "SKIP identity: no gpg"; echo "ALL PASS: test-offline-script (T-OFFLINE)"; exit 0; }
cp "$ROOT/bin/offline-tools/rnode-keygen/rnode-offline.sh" "$K/rnode-offline.sh"   # undo the tamper test above
ident() { # NAME EMAIL LABEL STICK1 STICK2 → runs option 3
	printf 'TOOLS_SHA256=%s\nRELEASE=fake.itb\nRELEASE_SHA256=\nRELEASE_KEYS=""\nMAINTAINER_NAME="%s"\nMAINTAINER_EMAIL="%s"\nFIRMWARE_LABEL="%s"\n' \
		"$tsha" "$1" "$2" "$3" >"$R/EXPECTED"
	cat >"$W/hook" <<H
#!/bin/sh
case "\$1" in
	*"Plug in KEY A"*) echo "$4" >"$W/sticks" ;;
	*"Plug in KEY B"*) echo "$5" >"$W/sticks" ;;
	*unplug*) : >"$W/sticks" ;;
esac
H
	printf 'y\ny\ncorrect horse battery\ncorrect horse battery\n\ny\n\n\ny\n\n' | bash "$K/rnode-offline.sh" 3
}
ident "Eugene Test" "eugene@example.org" A "$W/stickA" "$W/stickB" >"$W/id.out" 2>&1 || fail "identity: $(cat "$W/id.out")"
for st in stickA stickB; do
	for f in secret-full.asc revocation-certificate.asc public-key.asc ssh.pub gnupg-home.tar; do
		[ -s "$W/$st/pgp/$f" ] || fail "$st must hold pgp/$f"
	done
done
cmp -s "$W/stickA/release-key/rnode-release-A.sec" "$W/stickB/release-key/rnode-release-A.sec" || fail "firmware key A must be backed up on KEY B"
[ -s "$W/stickB/release-key/RETIRED-B.txt" ] && [ -s "$W/stickB/release-key/rnode-release-B.sec" ] || fail "old key B: marked retired, not deleted"
I="$R/identity"; fpA=$("$U" -F -s "$W/stickA/release-key/rnode-release-A.sec")
for f in public-key.asc ssh.pub secret-subkeys.asc "firmware-key-$fpA.pub" "firmware-key-$fpA.pub.asc" IDENTITY; do [ -s "$I/$f" ] || fail "identity/ must hold $f"; done
[ -z "$(find "$R" -name secret-full.asc -o -name revocation-certificate.asc -o -name '*.sec')" ] || fail "main key / revocation / secret reached the drive"
H=$(mktemp -d); chmod 700 "$H"
gpg --homedir "$H" --batch --import "$I/public-key.asc" "$I/secret-subkeys.asc" 2>/dev/null
gpg --homedir "$H" -K | grep -q '^sec#' || fail "drive copy must hold the everyday subkeys only (main key absent)"
gpg --homedir "$H" --list-keys --with-colons | grep -q '^uid:.*Eugene Test <eugene@example.org>' || fail "uid"
[ "$(gpg --homedir "$H" --list-keys --with-colons | awk -F: '/^sub:/{print $12}' | sort | tr -d '\n')" = aes ] || fail "subkeys a/e/s"
gpg --homedir "$H" --verify "$I/firmware-key-$fpA.pub.asc" "$I/firmware-key-$fpA.pub" 2>/dev/null || fail "firmware key must carry a valid PGP signature"
grep -q '^ssh-ed25519 ' "$I/ssh.pub" || fail "ssh.pub must be an ed25519 SSH key"
fpr=$(sed -n 's/^pgp=//p' "$I/IDENTITY"); grep -q "$fpr" "$W/id.out" || fail "PGP fingerprint must be shown"
gpgconf --homedir "$H" --kill all 2>/dev/null || true; rm -rf "$H"
pass "identity: PGP main key + subkeys and firmware key on BOTH sticks (checked), old key B marked retired; drive gets public keys + everyday subkeys only; firmware key PGP-signed"

mkdir -p "$W/stickP1" "$W/stickP2"
ident "Partner Test" "partner@example.org" P "$W/stickP1" "$W/stickP2" >"$W/idp.out" 2>&1 || fail "partner identity: $(cat "$W/idp.out")"
[ -s "$W/stickP1/release-key/rnode-release-P.sec" ] && cmp -s "$W/stickP1/release-key/rnode-release-P.sec" "$W/stickP2/release-key/rnode-release-P.sec" \
	|| fail "a new maintainer's firmware key is made on KEY A and backed up on KEY B"
pass "identity for a new maintainer: their own firmware key made and backed up"

echo "ALL PASS: test-offline-script (T-OFFLINE)"
