#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Start the RNode Factory Station and open it in the browser (on the station).
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$HOME/knots-factory/station.env" ] && . "$HOME/knots-factory/station.env"
PORT_HTTP=8099
if ! ss -ltn 2>/dev/null | grep -q ":$PORT_HTTP "; then
	nohup python3 "$HERE/rnode_station.py" --port "$PORT_HTTP" >>"$HOME/knots-factory/station.log" 2>&1 &
	sleep 1
fi
URL="http://127.0.0.1:$PORT_HTTP/"
echo "RNode Factory Station: $URL"
command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && xdg-open "$URL" >/dev/null 2>&1 || true
