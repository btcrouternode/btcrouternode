#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Release signatures for appliance upgrades (pre-production review,
# 2026-10-18). Images are signed with OpenWrt's usign on an OFFLINE machine
# (factory/release-keygen.sh, build/sign-release.sh) and the signature is
# appended to the .itb as an fwtool chunk. The firmware ships the trusted
# PUBLIC key(s) in /etc/knots/release-keys/<fingerprint>.
#
# Policy: as soon as a release key is installed, every Settings upgrade must
# carry a valid signature from it. Builds with no key installed (pre-production,
# before the release key exists) keep the pasted-SHA256-only behaviour.
# Sourced by settings-api.sh; paths overridable for tests.

RELEASE_KEYS="${KNOTS_RELEASE_KEYS:-/etc/knots/release-keys}"
RELEASE_USIGN="${KNOTS_USIGN:-usign}"
RELEASE_FWTOOL="${KNOTS_FWTOOL:-fwtool}"

# True when at least one usign public key (16-hex fingerprint name) is installed.
release_sig_required() {
	[ -d "$RELEASE_KEYS" ] || return 1
	ls "$RELEASE_KEYS" 2>/dev/null | grep -qE '^[0-9a-f]{16}$'
}

# release_sig_check IMAGE — strips an appended signature (the image becomes
# exactly what was signed) and verifies it. Sets RELEASE_SIG_STATE:
#   verified  signature valid against an installed key
#   unchecked no release key installed (pre-production): image untouched
#   unsigned  no signature chunk
#   invalid   signature present but wrong / tampered / unknown key (an image
#             that only carries OpenWrt's own build-key signature lands here)
# Returns 0 when the upgrade may proceed.
release_sig_check() {
	_img=$1
	# Pre-production (no release key installed): do not touch the image at
	# all. Image Builder output already carries OpenWrt's own build-key
	# signature chunk; stripping it changed the flashed bytes for nothing.
	if ! release_sig_required; then
		RELEASE_SIG_STATE=unchecked
		return 0
	fi
	_tmp="${TMPDIR:-/tmp}/knots-release-sig.$$"
	rm -f "$_tmp"
	"$RELEASE_FWTOOL" -q -t -s "$_tmp" "$_img" >/dev/null 2>&1 || true
	if [ ! -s "$_tmp" ]; then
		rm -f "$_tmp"
		RELEASE_SIG_STATE=unsigned
		return 1
	fi
	if "$RELEASE_USIGN" -V -q -m "$_img" -P "$RELEASE_KEYS" -x "$_tmp" >/dev/null 2>&1; then
		RELEASE_SIG_STATE=verified
		rm -f "$_tmp"
		return 0
	fi
	rm -f "$_tmp"
	RELEASE_SIG_STATE=invalid
	return 1
}
