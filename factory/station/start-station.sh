#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Start the RNode Factory Station and open it in the browser (on the station).
# The station keeps running in the background after its window is closed. A
# station still serving an OLDER bundle (25.0.32.0 lab, 2026-11-10: the new
# bundle was copied in, the shortcut only reopened the old station on
# 24.10.8.29.3.118) is restarted here — never in the middle of a batch.
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
[ -f "$HOME/knots-factory/station.env" ] && . "$HOME/knots-factory/station.env"
PORT_HTTP="${KNOTS_STATION_HTTP_PORT:-8099}"
URL="http://127.0.0.1:$PORT_HTTP/"
WANT=$(sh "$HERE/../../build/product-version.sh")

state() { # "<version> <stage>" of the running station, nothing if none answers
	python3 - "${URL}api/state" <<'PY' 2>/dev/null || true
import json, sys, urllib.request
s = json.load(urllib.request.urlopen(sys.argv[1], timeout=3))
print(s.get("version") or "?", s.get("stage") or "?")
PY
}
wait_state() { # until a station answers (up) or none does (down), 15 s
	i=0
	while [ $i -lt 30 ]; do
		s=$(state)
		if [ "$1" = up ]; then [ -n "$s" ] && return 0; else [ -z "$s" ] && return 0; fi
		sleep 0.5; i=$((i + 1))
	done
	return 1
}

set -- $(state)
if [ -n "${1:-}" ] && [ "$1" != "$WANT" ]; then
	case "${2:-}" in
		building|labelling)
			echo "The station is busy with a batch on $1 — let it finish, then start it again (bundle is $WANT)." >&2
			exit 1 ;;
	esac
	echo "Restarting the station: it is running $1, this bundle is $WANT"
	pkill -f "$HERE/rnode_station.py" || true
	wait_state down || { echo "the old station ($1) did not stop" >&2; exit 1; }
	set --
fi
if [ -z "${1:-}" ]; then
	nohup python3 "$HERE/rnode_station.py" --port "$PORT_HTTP" >>"$HOME/knots-factory/station.log" 2>&1 &
	wait_state up || { echo "the station did not start — see $HOME/knots-factory/station.log" >&2; exit 1; }
fi
set -- $(state)
[ "${1:-}" = "$WANT" ] || { echo "the station runs ${1:-?}, expected $WANT" >&2; exit 1; }
echo "RNode Factory Station $WANT: $URL"
command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && xdg-open "$URL" >/dev/null 2>&1 || true
