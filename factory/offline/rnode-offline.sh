#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# RNode offline key work — run on the offline laptop (live USB, no network).
# Owner (2026-10-27): no more typing long commands; the script finds the key
# sticks itself (wherever the live system opens them: /run/media or /media),
# checks every step, and asks only for clicks in Disks and Enter.
#
#   sudo -i
#   cd /run/media/*/*/home/*/rnode-sign/rnode-keygen && sha256sum SHA256SUMS && sha256sum -c --quiet SHA256SUMS && bash rnode-offline.sh
#     1) make new release keys A and B  → public halves to new-public/
#     2) sign the release in unsigned/  → signed/
#     3) make my maintainer identity    → identity/ (public keys + everyday subkeys)
# This script is IN the tools folder: the fingerprint printed before it starts
# (the live system's own sha256sum) covers it — compare it with the paper.
#
# The folder (rnode-sign/ on the build laptop's own drive) is staged by the
# build PC (build/stage-offline.sh): rnode-keygen/ (tools), EXPECTED (the
# fingerprints the build PC saw), release-keys/ (public keys built into the
# release), unsigned/ (the release). Secret keys only ever live on the sticks.
set -euo pipefail

S=$(cd "$(dirname "$0")/.." && pwd)     # rnode-sign/ (this script is in rnode-sign/rnode-keygen/)
T="${RNODE_OFFLINE_TMP:-/tmp/rnode-keygen}"
TEST="${RNODE_OFFLINE_TEST:-}"           # host tests: no root, fake sticks
OWNER="${RNODE_OFFLINE_OWNER:-1000:1000}"  # files written back belong to the laptop's user

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad()  { printf '\n  \033[31m✘ %s\033[0m\n\n' "$*" >&2; exit 1; }
big()  { printf '\n    \033[1;33m%s\033[0m\n\n' "$*"; }
TTY=/dev/tty; [ -z "$TEST" ] || TTY=/dev/stdin
# tests: a hook plays the person (plugs / unplugs fake sticks) at each prompt
pause() { [ -z "${RNODE_OFFLINE_HOOK:-}" ] || "$RNODE_OFFLINE_HOOK" "$*"; read -r -p "  → $* — then press Enter " _ <"$TTY"; }
yes_no() { local a; read -r -p "  → $* [y/N] " a <"$TTY"; [ "$a" = y ] || [ "$a" = Y ]; }
give_back() { [ -n "$TEST" ] || chown -R "$OWNER" "$@"; }

[ -n "$TEST" ] || [ "$(id -u)" = 0 ] || bad "run it with sudo:  sudo bash $0"
[ -f "$S/EXPECTED" ] || bad "no EXPECTED file in $S — the build PC stages this folder"
# shellcheck disable=SC1091
. "$S/EXPECTED"                          # TOOLS_SHA256, RELEASE, RELEASE_SHA256, RELEASE_KEYS

# Unlocked (LUKS) sticks that are open: their mount points, one per line.
# A key stick is always LUKS (/dev/mapper/…); the laptop's own drive is not.
open_sticks() {
	if [ -n "${RNODE_OFFLINE_STICKS:-}" ]; then cat "$RNODE_OFFLINE_STICKS"; return; fi
	python3 - <<'PY'
import os
for line in open("/proc/self/mountinfo"):
    f = line.split()
    src = f[f.index("-") + 2]
    if src.startswith("/dev/mapper/") and not src.startswith("/dev/mapper/ubuntu"):
        print(f[4].encode().decode("unicode_escape"))
PY
}

# Wait until exactly one key stick is unlocked and open; print its path.
find_stick() { # LABEL
	local L=$1 n m
	while true; do
		pause "Plug in KEY $L. In Disks: select it, click 🔓 (passphrase $L), then ▶ so it opens"
		mapfile -t m < <(open_sticks)
		n=${#m[@]}
		if [ "$n" = 1 ]; then
			echo "  Found an unlocked stick at: ${m[0]}"
			if yes_no "Is this KEY $L?"; then STICK=${m[0]}; return 0; fi
			echo "  Then lock and unplug that stick first."
		elif [ "$n" = 0 ]; then
			echo "  No unlocked key stick yet — in Disks click 🔓, enter passphrase $L, then ▶."
		else
			echo "  $n unlocked sticks are open — lock and unplug all but KEY $L."
		fi
	done
}

wait_unplugged() { # PATH LABEL
	while open_sticks | grep -qxF "$1"; do
		pause "In Disks: ■ (unmount) and 🔒 (lock) KEY $2, then unplug it"
	done
	ok "KEY $2 locked and away"
}

prepare_tools() {
	say "Checking the signing tools"
	rm -rf "$T"; cp -r "$S/rnode-keygen" "$T"
	( cd "$T" && sha256sum -c --quiet SHA256SUMS ) || bad "the tools do not match their own checksums — stop"
	local got; got=$(cd "$T" && sha256sum SHA256SUMS | cut -d' ' -f1)
	[ "$got" = "$TOOLS_SHA256" ] || bad "tools fingerprint $got is not the one the build PC staged ($TOOLS_SHA256) — stop"
	chmod +x "$T"/*.sh "$T"/usign/bin/* "$T"/usign/bin/.*.bin "$T"/usign/lib/ld-linux-x86-64.so.2
	echo "  Tools fingerprint (compare with your paper):"; big "$got"
	yes_no "Does it match your paper?" || bad "stopped — the tools may have been changed"
	ok "tools checked"
}

no_secret_left() {
	local n; n=$( { find "$T" "$S" -name '*.sec' 2>/dev/null || true; } | wc -l)
	[ "$n" = 0 ] || bad "a secret key file is outside the sticks — stop and tell the engineer"
	ok "no secret key anywhere but the sticks"
}

make_keys() {
	prepare_tools
	# public halves collect in a scratch folder and replace new-public/ only when
	# BOTH keys succeeded — a stopped or mistaken run never loses good keys
	local out="$S/new-public.partial" fpA="" fpB="" L key pub
	rm -rf "$out"; mkdir -p "$out"
	for L in A B; do
		say "Key $L"
		find_stick "$L"
		key="$STICK/release-key/rnode-release-$L.sec"
		[ ! -e "$key" ] || bad "KEY $L already holds a key ($key) — this tool never overwrites one"
		bash "$T/release-keygen.sh" "$STICK/release-key" "$L" "$out" >/dev/null || bad "making key $L failed"
		sync
		# The proof .116/.117 lacked: the secret is ON THE STICK and works from there.
		[ -s "$key" ] || bad "key $L is not on the stick ($key) — stop"
		pub="$STICK/release-key/rnode-release-$L.pub"
		echo "RNode key $L check" >"$T/check.msg"
		"$T/usign/bin/usign" -S -m "$T/check.msg" -s "$key" -x "$T/check.sig" \
			&& "$T/usign/bin/usign" -V -q -m "$T/check.msg" -p "$pub" -x "$T/check.sig" \
			|| bad "key $L on the stick does not sign and verify — stop"
		rm -f "$T/check.msg" "$T/check.sig"
		local fp; fp=$("$T/usign/bin/usign" -F -p "$pub")
		[ -f "$out/$fp" ] || bad "public key $L was not saved to $out"
		ok "key $L is on the stick and signs + verifies from it"
		echo "  Write down fingerprint $L:"; big "$fp"
		if [ "$L" = A ]; then fpA=$fp; else fpB=$fp; fi
		wait_unplugged "$STICK" "$L"
	done
	no_secret_left
	rm -rf "$S/new-public.previous"
	[ ! -d "$S/new-public" ] || mv "$S/new-public" "$S/new-public.previous"
	mv "$out" "$S/new-public"; out="$S/new-public"; sync
	give_back "$out"
	say "Done — new keys made"
	echo "  KEY A: $fpA"
	echo "  KEY B: $fpB"
	echo "  The public halves are in $out (the build PC picks them up)."
	echo "  Shut down, remove the live USB, reconnect the network, start normally."
}

sign_release() {
	prepare_tools
	local img="$S/unsigned/$RELEASE" key fp f got
	[ -f "$img" ] || bad "no release $img"
	say "Checking the release"
	cp "$img" "$T/$RELEASE"
	got=$(sha256sum "$T/$RELEASE" | cut -d' ' -f1)
	[ "$got" = "$RELEASE_SHA256" ] || bad "release fingerprint $got is not the one the build PC staged — stop"
	echo "  $RELEASE"
	echo "  Unsigned release fingerprint (compare with your paper):"; big "$got"
	yes_no "Does it match your paper?" || bad "stopped — the release may have been changed"
	say "Signing with KEY A"
	find_stick A
	key="$STICK/release-key/rnode-release-A.sec"
	[ -s "$key" ] || bad "there is no key on this stick ($key)"
	fp=$("$T/usign/bin/usign" -F -s "$key")
	case " $RELEASE_KEYS " in *" $fp "*) ;; *) bad "this KEY A ($fp) is not one of the keys built into this release ($RELEASE_KEYS) — stop" ;; esac
	bash "$T/sign-image.sh" "$key" "$T/$RELEASE" >/dev/null || bad "signing failed"
	# Verify exactly like the router: strip the outer signature, check it against
	# the public keys built into this release.
	rm -f "$T/v.img" "$T/v.sig"; cp "$T/$RELEASE" "$T/v.img"
	"$T/usign/bin/fwtool" -q -t -s "$T/v.sig" "$T/v.img" >/dev/null 2>&1 || true
	"$T/usign/bin/usign" -V -q -m "$T/v.img" -P "$S/release-keys" -x "$T/v.sig" \
		|| bad "the signed release does not verify against this release's keys — stop"
	rm -f "$T/v.img" "$T/v.sig"
	ok "signed with key $fp and verified like the router does"
	mkdir -p "$S/signed"; rm -f "$S/signed"/*.itb
	cp "$T/$RELEASE" "$S/signed/$RELEASE"; sync
	give_back "$S/signed"
	f=$(sha256sum "$S/signed/$RELEASE" | cut -d' ' -f1)
	echo "  Write down the SIGNED release fingerprint (the official one):"; big "$f"
	wait_unplugged "$STICK" A
	no_secret_left
	say "Done — release signed"
	echo "  Shut down, remove the live USB, reconnect the network, start normally."
}

# --- 3) a maintainer's identity (docs/RELEASE_PROCESS.md §3) -------------------
# One PGP identity per maintainer, made here offline: main key (certify only, no
# expiry; revocation certificate) + signing / SSH / encryption subkeys (2 years).
# Both sticks (KEY A primary, KEY B backup) get the FULL identity and the
# maintainer's firmware (usign) key; the laptop's drive gets only the public
# key, the SSH public key and the passphrase-protected EVERYDAY subkeys (never
# the main key), plus the firmware public key signed with the PGP key.
gpgq() { gpg --homedir "$G" --batch --pinentry-mode loopback --passphrase-fd 3 "$@" 3< <(printf '%s' "$PASS"); }

write_identity() { # STICK — copy the identity onto a stick and prove it is there
	local d="$1/pgp"
	mkdir -p "$d"
	cp "$ID/secret-full.asc" "$ID/revocation-certificate.asc" "$ID/public-key.asc" "$ID/ssh.pub" "$d/"
	gpgconf --homedir "$G" --kill all 2>/dev/null || true     # no agent sockets in the copy
	tar -C "$G" -cf "$d/gnupg-home.tar" . 2>/dev/null
	sync
	( cd "$ID" && sha256sum secret-full.asc revocation-certificate.asc public-key.asc ) >"$T/id.sums"
	( cd "$d" && sha256sum -c --quiet "$T/id.sums" ) || bad "the identity on the stick does not read back correctly — stop"
	# the main key on the stick must import and sign
	local h="$T/gnupg-check"; rm -rf "$h"; mkdir -m 700 "$h"
	gpg --homedir "$h" --batch --import "$d/secret-full.asc" 2>/dev/null
	gpg --homedir "$h" --list-secret-keys --with-colons "$FPR" | grep -q '^sec:' \
		&& ! gpg --homedir "$h" -K "$FPR" | grep -q '^sec#' || bad "the main key on the stick is not complete — stop"
	echo check | gpg --homedir "$h" --batch --pinentry-mode loopback --passphrase-fd 3 -u "$FPR" --clearsign \
		3< <(printf '%s' "$PASS") >/dev/null 2>&1 || bad "the key on the stick does not sign — stop"
	gpgconf --homedir "$h" --kill all 2>/dev/null || true; rm -rf "$h"
}

make_identity() {
	prepare_tools
	command -v gpg >/dev/null 2>&1 || bad "gpg is not available in this live system"
	[ -n "${MAINTAINER_NAME:-}" ] && [ -n "${MAINTAINER_EMAIL:-}" ] && [ -n "${FIRMWARE_LABEL:-}" ] \
		|| bad "EXPECTED has no MAINTAINER_NAME / MAINTAINER_EMAIL / FIRMWARE_LABEL — the build PC stages them"
	local uid="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"
	say "Your maintainer identity"
	big "$uid"
	yes_no "Are this name and email right? They become public and permanent" || bad "stopped — ask the build PC to stage the right name and email"
	local p2
	while true; do
		read -r -s -p "  → Choose a passphrase for your PGP keys (12+ characters; write it down, labelled PGP): " PASS <"$TTY"; echo
		read -r -s -p "  → The same passphrase again: " p2 <"$TTY"; echo
		[ "$PASS" = "$p2" ] && [ ${#PASS} -ge 12 ] && break
		echo "  They differ or are shorter than 12 characters — once more."
	done
	G="$T/gnupg"; ID="$T/identity"; rm -rf "$G" "$ID"; mkdir -m 700 -p "$G" "$ID"
	say "Making the keys"
	gpgq --quick-gen-key "$uid" ed25519 cert 0 2>/dev/null || bad "making the main key failed"
	FPR=$(gpg --homedir "$G" --list-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}')
	gpgq --quick-add-key "$FPR" ed25519 sign 2y 2>/dev/null \
		&& gpgq --quick-add-key "$FPR" ed25519 auth 2y 2>/dev/null \
		&& gpgq --quick-add-key "$FPR" cv25519 encr 2y 2>/dev/null || bad "making the subkeys failed"
	[ "$(gpg --homedir "$G" --list-keys --with-colons "$FPR" | awk -F: '/^sub:/{print $12}' | sort | tr -d '\n')" = aes ] \
		|| bad "the subkeys are not as expected — stop"
	gpg --homedir "$G" --armor --export "$FPR" >"$ID/public-key.asc"
	gpgq --armor --export-secret-keys "$FPR" >"$ID/secret-full.asc" 2>/dev/null
	gpgq --armor --export-secret-subkeys "$FPR" >"$ID/secret-subkeys.asc" 2>/dev/null
	gpg --homedir "$G" --export-ssh-key "$FPR" >"$ID/ssh.pub" 2>/dev/null
	cp "$G/openpgp-revocs.d/$FPR.rev" "$ID/revocation-certificate.asc"
	[ -s "$ID/secret-full.asc" ] && [ -s "$ID/secret-subkeys.asc" ] && [ -s "$ID/ssh.pub" ] || bad "exporting the keys failed"
	ok "PGP identity made: main key + signing, SSH and encryption subkeys"

	local L=$FIRMWARE_LABEL fwkey fwpub fwfp
	say "KEY A — your primary stick"
	find_stick A
	write_identity "$STICK"
	ok "identity on KEY A, checked"
	fwkey="$STICK/release-key/rnode-release-$L.sec"
	if [ ! -s "$fwkey" ]; then   # a new maintainer: make the firmware key now, on this stick
		bash "$T/release-keygen.sh" "$STICK/release-key" "$L" >/dev/null || bad "making the firmware key failed"
		sync; [ -s "$fwkey" ] || bad "the firmware key is not on the stick — stop"
		ok "firmware key made on KEY A"
	fi
	fwpub="$STICK/release-key/rnode-release-$L.pub"
	fwfp=$("$T/usign/bin/usign" -F -p "$fwpub")
	mkdir -p "$T/fw"; cp "$fwkey" "$fwpub" "$T/fw/"
	cp "$fwpub" "$ID/firmware-key-$fwfp.pub"
	# tie the firmware key to the PGP identity: the PGP signing subkey signs it
	gpgq -u "$FPR" --armor --detach-sign -o "$ID/firmware-key-$fwfp.pub.asc" "$ID/firmware-key-$fwfp.pub" 2>/dev/null \
		|| bad "signing the firmware key with your PGP key failed"
	ok "firmware key $fwfp signed with your PGP key"
	wait_unplugged "$STICK" A

	say "KEY B — your backup stick"
	find_stick B
	write_identity "$STICK"
	mkdir -p "$STICK/release-key"
	if [ -e "$STICK/release-key/rnode-release-$L.sec" ]; then
		cmp -s "$T/fw/rnode-release-$L.sec" "$STICK/release-key/rnode-release-$L.sec" \
			|| bad "KEY B already holds a different firmware key $L — this tool never overwrites one"
	else
		cp "$T/fw/rnode-release-$L.sec" "$T/fw/rnode-release-$L.pub" "$STICK/release-key/"
	fi
	if [ "$L" = A ] && [ -e "$STICK/release-key/rnode-release-B.sec" ]; then
		echo "Key B ($("$T/usign/bin/usign" -F -p "$STICK/release-key/rnode-release-B.pub" 2>/dev/null)) is RETIRED: one firmware key per maintainer (docs/RELEASE_PROCESS.md)." \
			>"$STICK/release-key/RETIRED-B.txt"
	fi
	sync
	cmp -s "$T/fw/rnode-release-$L.sec" "$STICK/release-key/rnode-release-$L.sec" || bad "the firmware key backup does not read back — stop"
	ok "identity and firmware key backup on KEY B, checked"
	wait_unplugged "$STICK" B

	# The drive gets only what may leave the offline laptop.
	local h="$T/gnupg-sub"; rm -rf "$h"; mkdir -m 700 "$h"
	gpg --homedir "$h" --batch --import "$ID/secret-subkeys.asc" 2>/dev/null
	gpg --homedir "$h" -K "$FPR" | grep -q '^sec#' || bad "the everyday subkeys file contains the main key — stop"
	gpgconf --homedir "$h" --kill all 2>/dev/null || true; rm -rf "$h"
	local out="$S/identity"; rm -rf "$out"; mkdir -p "$out"
	cp "$ID/public-key.asc" "$ID/ssh.pub" "$ID/secret-subkeys.asc" "$ID/firmware-key-$fwfp.pub" "$ID/firmware-key-$fwfp.pub.asc" "$out/"
	printf 'name=%s\nemail=%s\npgp=%s\nfirmware=%s\n' "$MAINTAINER_NAME" "$MAINTAINER_EMAIL" "$FPR" "$fwfp" >"$out/IDENTITY"
	sync; give_back "$out"
	gpgconf --homedir "$G" --kill all 2>/dev/null || true
	rm -rf "$G" "$ID" "$T/fw" "$T/id.sums"; PASS=""
	[ ! -e "$S/identity/secret-full.asc" ] && [ -z "$(find "$S" -name 'revocation-certificate.asc')" ] \
		|| bad "the main key or revocation certificate reached the drive — stop and tell the engineer"
	no_secret_left
	say "Done — your maintainer identity"
	echo "  Write down your PGP fingerprint:"; big "$FPR"
	echo "  Firmware key: $fwfp"
	echo "  Both sticks hold the full identity, the revocation certificate and the firmware key."
	echo "  The laptop's drive holds only your public keys and the passphrase-protected everyday subkeys."
	echo "  Shut down, remove the live USB, reconnect the network, start normally."
}

say "RNode offline keys — $(basename "$S")"
echo "  1) Make new release keys A and B"
echo "  2) Sign the release ($RELEASE)"
echo "  3) Make my maintainer identity (PGP + firmware key)${MAINTAINER_NAME:+ — $MAINTAINER_NAME}"
choice="${1:-}"
[ -n "$choice" ] || read -r -p "  → Choose 1, 2 or 3: " choice <"$TTY"
case "$choice" in
	1|keys) make_keys ;;
	2|sign) sign_release ;;
	3|identity) make_identity ;;
	*) bad "choose 1, 2 or 3" ;;
esac
