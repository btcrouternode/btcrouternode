#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Run all host IUE / first-run Setup tests (U17 / N13 / U19).
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
chmod +x "$ROOT/tests/host/test-iue-flow.sh" \
	"$ROOT/tests/host/test-iue-tls-os.sh" \
	"$ROOT/tests/host/test-tls-install-scripts.sh" \
	"$ROOT/tests/host/test-node-ui-tls-local-ca.sh" \
	"$ROOT/tests/host/test-http-setup-iue.sh"
"$ROOT/tests/host/test-iue-flow.sh"
"$ROOT/tests/host/test-iue-tls-os.sh"
# Prefer freshly minted CA from tls-os run is internal; still run script syntax suite
"$ROOT/tests/host/test-tls-install-scripts.sh"
"$ROOT/tests/host/test-node-ui-tls-local-ca.sh"
echo "=== test-iue (host) PASSED ==="
