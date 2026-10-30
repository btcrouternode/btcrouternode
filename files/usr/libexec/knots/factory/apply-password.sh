#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Factory admin password (R13/P1): per-device label secret, else knotsnode21
# Discard passwd prompts so callers (and any CGI) never see non-JSON stdout.

# P1 (review 2026-10-10): the label's per-device secret when provisioned,
# else the legacy shared password (unlabelled units: Wi-Fi stays off).
# shellcheck disable=SC1091
. /usr/libexec/knots/setup-lib.sh 2>/dev/null || true
if command -v knots_factory_password >/dev/null 2>&1; then
	PASS=$(knots_factory_password)
else
	PASS='knotsnode21'
fi

if command -v chpasswd >/dev/null 2>&1; then
	printf 'root:%s\n' "$PASS" | chpasswd >/dev/null 2>&1
else
	printf '%s\n%s\n' "$PASS" "$PASS" | passwd root >/dev/null 2>&1
fi

exit 0
