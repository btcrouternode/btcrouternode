#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Installed on the laptop as ~/Documents/knots-uat/run
cd "$(dirname "$0")" || exit 1
PY="./.venv/bin/python3"
[ -x "$PY" ] || PY=python3
if ! "$PY" -c "from playwright.sync_api import sync_playwright" >/dev/null 2>&1; then
	echo "IUE UAT needs Playwright Chromium (clicks Welcome/Security/Quick/Guided)." >&2
	echo "On this laptop, once:" >&2
	echo "  sudo apt-get install -y python3-pip python3-venv" >&2
	echo "  python3 -m venv $HOME/Documents/knots-uat/.venv" >&2
	echo "  $HOME/Documents/knots-uat/.venv/bin/pip install playwright" >&2
	echo "  $HOME/Documents/knots-uat/.venv/bin/playwright install chromium" >&2
	echo "  sudo $HOME/Documents/knots-uat/.venv/bin/playwright install-deps chromium" >&2
	exit 1
fi
exec "$PY" ./uat-web.py "$@"
