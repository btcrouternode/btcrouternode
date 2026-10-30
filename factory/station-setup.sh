#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Prepare a FACTORY STATION (production laptop) — run ON the station, from the
# station bundle (make factory-station). Idempotent; safe to re-run.
#
#   1. packages: python3-serial, python3-pil, openssl, rsync
#      (asks for the station user's sudo password if something is missing)
#   2. serial port access (dialout group — log out and in afterwards)
#   3. ~/knots-factory (mode 700):
#        station_ed25519[.pub]  ssh key the production script installs on a
#                               unit via the console and removes at the end
#        factory key            --test-factory-key creates factory-TEST.key for
#                               a simulation; the REAL key is created here by the
#                               owner with --create-factory-key (never copied off
#                               this station except to its offline backup)
#        labels.csv             inventory written by provisioning (no passwords —
#                               recalculated from the factory key; recover-sticker.py)
#        station.env            exports for the production scripts
#   4. checks: USB serial adapter, SD card reader, Ethernet to the unit
#
# Usage: factory/station-setup.sh [--test-factory-key | --create-factory-key] [--check]
set -euo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KF="${KNOTS_FACTORY_DIR:-$HOME/knots-factory}"
MODE=""; CHECK_ONLY=0
for a in "$@"; do
	case "$a" in
		--test-factory-key) MODE=test ;;
		--create-factory-key) MODE=real ;;
		--check) CHECK_ONLY=1 ;;
		-h|--help) sed -n '2,22p' "$0"; exit 0 ;;
		*) echo "unknown argument: $a" >&2; exit 2 ;;
	esac
done
ok() { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mTODO\033[0m %s\n' "$*"; }

echo "== 1. packages"
need=""
python3 -c 'import serial' 2>/dev/null || need="$need python3-serial"
python3 -c 'import PIL' 2>/dev/null || need="$need python3-pil"
for c in openssl rsync; do command -v "$c" >/dev/null 2>&1 || need="$need $c"; done
dpkg -s tftpd-hpa >/dev/null 2>&1 || need="$need tftpd-hpa"
if [ -z "$need" ]; then ok "python3-serial, python3-pil, openssl, rsync, tftpd-hpa"
elif [ "$CHECK_ONLY" = 1 ]; then warn "missing:$need"
else
	echo "  installing:$need (asks for this computer's sudo password)"
	sudo apt-get update -qq && sudo apt-get install -y $need && ok "installed:$need"
fi

echo "== 1b. TFTP server + station address (TFTP install, no SD card)"
TFTP_DIR=/srv/tftp
STATION_IP=${RNODE_STATION_IP:-192.168.1.10}
if [ -d "$TFTP_DIR" ] && [ -w "$TFTP_DIR" ]; then ok "TFTP root $TFTP_DIR writable"
elif [ "$CHECK_ONLY" = 1 ]; then warn "TFTP root $TFTP_DIR missing or not writable"
else sudo mkdir -p "$TFTP_DIR" && sudo chown "$USER" "$TFTP_DIR" && ok "TFTP root $TFTP_DIR owned by $USER"; fi
if ss -lun 2>/dev/null | grep -q ':69 '; then ok "TFTP server listening (UDP 69)"
elif [ "$CHECK_ONLY" = 1 ]; then warn "no TFTP server on UDP 69"
else sudo systemctl enable --now tftpd-hpa && ok "tftpd-hpa started"; fi
IFACE=${RNODE_STATION_IFACE:-$(ip -o link | awk -F': ' '$2 ~ /^(en|eth)/ && !f {print $2; f=1}')}
if nmcli -t -f NAME con show 2>/dev/null | grep -qx rnode-factory; then ok "network profile rnode-factory ($STATION_IP on $IFACE)"
elif [ "$CHECK_ONLY" = 1 ]; then warn "no network profile rnode-factory (fixed $STATION_IP on $IFACE)"
elif [ -n "$IFACE" ]; then
	sudo nmcli con add type ethernet ifname "$IFACE" con-name rnode-factory ipv4.method manual \
		ipv4.addresses "$STATION_IP/24" ipv6.method disabled connection.autoconnect yes \
		connection.autoconnect-priority 50 >/dev/null && sudo nmcli con up rnode-factory >/dev/null 2>&1 || true
	ok "network profile rnode-factory: $STATION_IP/24 on $IFACE (no gateway; internet stays on Wi-Fi)"
else warn "no Ethernet interface found"; fi

echo "== 2. serial port access"
if id -nG | tr ' ' '\n' | grep -qx dialout; then ok "in group dialout"
elif getent group dialout | grep -qw "$USER"; then warn "added to dialout — log out and back in to use it"
elif [ "$CHECK_ONLY" = 1 ]; then warn "not in group dialout"
else sudo usermod -aG dialout "$USER"; warn "added to dialout — log out and back in (or reboot) before the first run"; fi

echo "== 3. ~/knots-factory"
( umask 077; mkdir -p "$KF" ); chmod 700 "$KF"
if [ ! -f "$KF/station_ed25519" ]; then
	if [ "$CHECK_ONLY" = 1 ]; then warn "no station ssh key"
	else ssh-keygen -q -t ed25519 -N '' -C rnode-factory-station -f "$KF/station_ed25519"; ok "station ssh key created"; fi
else ok "station ssh key $KF/station_ed25519"; fi

FKEY=""
[ -f "$KF/factory.key" ] && FKEY="$KF/factory.key"
[ -z "$FKEY" ] && [ -f "$KF/factory-TEST.key" ] && FKEY="$KF/factory-TEST.key"
case "$MODE" in
	test)
		if [ ! -f "$KF/factory-TEST.key" ]; then
			( umask 077; head -c 32 /dev/urandom >"$KF/factory-TEST.key" ); ok "TEST factory key created (simulation only — its labels are not for sale)"
		fi
		FKEY="$KF/factory-TEST.key" ;;
	real)
		if [ -f "$KF/factory.key" ]; then ok "factory key already exists — not overwritten"
		else ( umask 077; head -c 32 /dev/urandom >"$KF/factory.key" ); ok "FACTORY KEY created: $KF/factory.key — back it up offline now (encrypted USB), never copy it anywhere else"; fi
		FKEY="$KF/factory.key" ;;
esac
if [ -n "$FKEY" ]; then
	chmod 400 "$FKEY"; ok "factory key: $FKEY$( [ "${FKEY##*/}" = factory-TEST.key ] && echo '  (TEST)')"
else warn "no factory key (simulation: --test-factory-key; production: owner runs --create-factory-key)"; fi

cat >"$KF/station.env" <<EOF
# RNode factory station — source before running the production scripts:
#   . ~/knots-factory/station.env
export PORT=\${PORT:-/dev/ttyUSB0}
export ROUTER_SSH=\${ROUTER_SSH:-root@192.168.1.254}
export KNOTS_STATION_KEY=$KF/station_ed25519
export KNOTS_FACTORY_KEY_FILE=${FKEY}
export KNOTS_LABELS_CSV=$KF/labels.csv
export RNODE_FACTORY_HOME=$HERE
EOF
chmod 600 "$KF/station.env"; ok "station.env written"

echo "== 4. hardware"
ser=$(for d in /dev/ttyUSB* /dev/ttyACM*; do [ -e "$d" ] && printf '%s ' "$d"; done; true)
[ -n "$ser" ] && ok "serial adapter(s): $ser" || warn "no USB serial adapter plugged in (/dev/ttyUSB0)"
if lsblk -dno NAME,RM,TRAN | awk '$2==1 && ($3=="usb" || $1 ~ /^mmcblk/)' | grep -q .; then
	ok "removable disk present (SD reader — only for the SD route)"
else printf '  info no SD card reader — not needed for the TFTP route (station screen)\n'; fi
if ip -4 -br addr 2>/dev/null | awk '$1 ~ /^(en|eth)/ && $3 ~ /^192\.168\.1\./' | grep -q .; then
	ok "Ethernet on 192.168.1.0/24: $(ip -4 -br addr | awk '$1 ~ /^(en|eth)/ {print $1" "$3}' | tr '\n' ' ')"
else warn "no Ethernet address on 192.168.1.0/24 — cable the unit's LAN port to this station"; fi
ping -c1 -W2 192.168.1.254 >/dev/null 2>&1 && printf '  info 192.168.1.254 answers — fine if it is the router you are about to build (only routers of this batch on this cable)\n' || true

echo "== station screen"
D="$HOME/Desktop"; [ -d "$D" ] || D="$HOME"
if [ "$CHECK_ONLY" != 1 ]; then
	cat >"$D/rnode-factory-station.desktop" <<EOF2
[Desktop Entry]
Type=Application
Name=RNode Factory Station
Exec=$HERE/factory/station/start-station.sh
Terminal=false
Icon=network-wired
EOF2
	chmod +x "$D/rnode-factory-station.desktop"
	# GNOME shows new launchers as "untrusted" until marked (= right-click → Allow Launching)
	DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus} \
		gio set "$D/rnode-factory-station.desktop" metadata::trusted true 2>/dev/null || true
	ok "desktop shortcut: $D/rnode-factory-station.desktop (or run $HERE/factory/station/start-station.sh)"
fi

echo "== images"
ls -1 "$HERE"/images/*/ 2>/dev/null | sed 's/^/  /' || warn "no images in $HERE/images"
echo
echo "Next: . ~/knots-factory/station.env — then follow \$RNODE_FACTORY_HOME/factory/PRODUCTION.md"
