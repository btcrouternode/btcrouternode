#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-UAT-WEB — laptop LAN web UAT / regression (Phase 2 Node SKU).
# Runs on the Ubuntu laptop that has Ethernet to 192.168.1.254.
# No serial. No SD/eMMC flash (R5a). No M.2 wipe (S7).
#
#   ./uat-web.sh
#   START_AT=upgrade_keep ./uat-web.sh
#   ONLY=pages,status,nav ./uat-web.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/.venv/bin/python3"
[ -x "$PY" ] || PY=python3
if ! "$PY" -c "from playwright.sync_api import sync_playwright" >/dev/null 2>&1; then
	echo "IUE UAT needs Playwright Chromium (clicks Welcome/Security/Quick/Guided)." >&2
	echo "On this laptop, once:" >&2
	echo "  sudo apt-get install -y python3-pip python3-venv" >&2
	echo "  python3 -m venv $HERE/.venv" >&2
	echo "  $HERE/.venv/bin/pip install playwright" >&2
	echo "  $HERE/.venv/bin/playwright install chromium" >&2
	echo "  sudo $HERE/.venv/bin/playwright install-deps chromium" >&2
	exit 1
fi
exec "$PY" "$HERE/uat-web.py" "$@"
