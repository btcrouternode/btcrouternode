#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Build this router's "secure connection" package for Ubuntu / Debian / Mint.
#
# Owner (2026-10-25): Linux gets the same feel as the Mac — click Enable
# Secure Connection → the downloaded package opens in App Center → Install →
# password. No Terminal. The package carries this router's CA (restricted to
# home-network names) and on install:
#   - adds it to the system trust store (update-ca-certificates)
#   - Firefox (snap and deb): /etc/firefox/policies Certificates.Install —
#     read at Firefox's next start (Setup says: close Firefox and reopen it)
#   - Chrome / Chromium: each user's own store, when NSS certutil is installed
# Removing the package undoes all of it.
#
#   mk-trust-deb.sh CA.pem UNIT-NAME OUT.deb
# BusyBox-only (runs on the router): tar + gzip, the ar container by printf.
set -eu
umask 022
CA=$1; UNIT=${2:-rnode}; OUT=$3
case "$UNIT" in *[!a-z0-9-]*|"") UNIT=rnode ;; esac
PKG="${UNIT}-secure-connection"
VER="1.$(date -u +%Y%m%d%H%M%S)"
W=$(mktemp -d "${TMPDIR:-/tmp}/trust-deb.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM

grep -q "BEGIN CERTIFICATE" "$CA" || { echo "mk-trust-deb: not a certificate: $CA" >&2; exit 1; }

# --- data: the CA where update-ca-certificates looks ------------------------
mkdir -p "$W/data/usr/local/share/ca-certificates"
cp "$CA" "$W/data/usr/local/share/ca-certificates/${UNIT}.crt"
chmod 644 "$W/data/usr/local/share/ca-certificates/${UNIT}.crt"

# --- data: reopen the secure Setup page after the install (owner, 2026-10-25:
# "it should relaunch the website"). Runs as the desktop user, started by
# postinst through that user's systemd. Firefox reads the new policy only at
# start, so a running Firefox is restarted on the page (as the Terminal
# command does); otherwise the default browser opens it.
mkdir -p "$W/data/usr/libexec/${PKG}"
cat >"$W/data/usr/libexec/${PKG}/reopen-setup" <<EOF
#!/bin/sh
URL="https://${UNIT}.local/setup.html?after_tls=1"
me=\$(id -u)
sleep 2
ff=""
for b in /snap/bin/firefox /usr/bin/firefox /usr/bin/firefox-esr; do
	[ -x "\$b" ] && { ff=\$b; break; }
done
if [ -n "\$ff" ] && pgrep -u "\$me" -x 'firefox|firefox-bin|firefox-esr' >/dev/null 2>&1; then
	pkill -u "\$me" -x 'firefox|firefox-bin|firefox-esr' 2>/dev/null || true
	i=0
	while pgrep -u "\$me" -x 'firefox|firefox-bin|firefox-esr' >/dev/null 2>&1 && [ \$i -lt 20 ]; do
		sleep 0.5; i=\$((i + 1))
	done
	sleep 1
	exec "\$ff" --new-window "\$URL"
fi
exec xdg-open "\$URL"
EOF
chmod 755 "$W/data/usr/libexec/${PKG}/reopen-setup"

# --- control ------------------------------------------------------------------
mkdir -p "$W/control"
cat >"$W/control/control" <<EOF
Package: ${PKG}
Version: ${VER}
Architecture: all
Maintainer: RNode router <setup@${UNIT}.local>
Depends: ca-certificates
Section: misc
Priority: optional
Description: Secure connection to your RNode router (${UNIT})
 Lets the browsers on this computer open https://${UNIT}.local without
 warnings. It trusts only this router's own certificate, which is
 restricted to home-network names. Remove this package to undo it.
EOF

cat >"$W/control/postinst" <<'EOF'
#!/bin/sh
set -e
UNIT=@UNIT@
CRT=/usr/local/share/ca-certificates/$UNIT.crt
FFP=/etc/firefox/policies
update-ca-certificates >/dev/null 2>&1 || true
# Firefox (snap and deb) reads /etc/firefox/policies at its next start.
mkdir -p "$FFP"
cp "$CRT" "$FFP/$UNIT.crt"; chmod 644 "$FFP/$UNIT.crt"
python3 - "$FFP/policies.json" "$FFP/$UNIT.crt" add <<'PY' || true
@MERGE@
PY
# Chrome / Chromium keep their own store per user (needs libnss3-tools).
if command -v certutil >/dev/null 2>&1; then
	for d in /home/*/.pki/nssdb; do
		[ -d "$d" ] || continue
		u=$(ls -ld "$d" | awk '{print $3}')
		runuser -u "$u" -- certutil -d "sql:$d" -D -n "RNode $UNIT" >/dev/null 2>&1 || true
		runuser -u "$u" -- certutil -d "sql:$d" -A -t "C,," -n "RNode $UNIT" -i "$CRT" >/dev/null 2>&1 || true
	done
fi
# Reopen the secure Setup page for whoever is at the desktop, through their
# own systemd (so it outlives this install and has their display).
REOPEN=/usr/libexec/@PKG@/reopen-setup
for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
	[ "$(loginctl show-session "$s" -p Active --value 2>/dev/null)" = yes ] || continue
	case "$(loginctl show-session "$s" -p Type --value 2>/dev/null)" in wayland|x11) ;; *) continue ;; esac
	u=$(loginctl show-session "$s" -p Name --value 2>/dev/null)
	uid=$(id -u "$u" 2>/dev/null) || continue
	systemd-run --user -M "$u@" --collect --quiet "$REOPEN" >/dev/null 2>&1 || \
		runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
			DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
			systemd-run --user --collect --quiet "$REOPEN" >/dev/null 2>&1 || true
done
exit 0
EOF

cat >"$W/control/postrm" <<'EOF'
#!/bin/sh
set -e
UNIT=@UNIT@
FFP=/etc/firefox/policies
case "$1" in
	remove|purge)
		update-ca-certificates --fresh >/dev/null 2>&1 || true
		python3 - "$FFP/policies.json" "$FFP/$UNIT.crt" remove <<'PY' || true
@MERGE@
PY
		rm -f "$FFP/$UNIT.crt"
		if command -v certutil >/dev/null 2>&1; then
			for d in /home/*/.pki/nssdb; do
				[ -d "$d" ] || continue
				runuser -u "$(ls -ld "$d" | awk '{print $3}')" -- certutil -d "sql:$d" -D -n "RNode $UNIT" >/dev/null 2>&1 || true
			done
		fi
		;;
esac
exit 0
EOF

# Firefox policy merge: add / remove one Certificates.Install entry; never
# rewrite a policies.json we cannot read (other policies stay untouched).
cat >"$W/merge.py" <<'EOF'
import json, os, sys
path, crt, mode = sys.argv[1:4]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        sys.exit(0)
pol = data.setdefault("policies", {})
certs = pol.setdefault("Certificates", {})
inst = certs.setdefault("Install", [])
if mode == "add":
    if crt not in inst:
        inst.append(crt)
else:
    while crt in inst:
        inst.remove(crt)
    if not inst:
        certs.pop("Install")
    if not certs:
        pol.pop("Certificates")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.replace(tmp, path)
EOF
for f in postinst postrm; do
	awk -v unit="$UNIT" -v pkg="$PKG" -v mf="$W/merge.py" '
		/^@MERGE@$/ { while ((getline l < mf) > 0) print l; close(mf); next }
		{ gsub(/@UNIT@/, unit); gsub(/@PKG@/, pkg); print }' "$W/control/$f" >"$W/control/$f.new"
	mv "$W/control/$f.new" "$W/control/$f"
	chmod 755 "$W/control/$f"
done
chmod 644 "$W/control/control"

echo "2.0" >"$W/debian-binary"
( cd "$W/control" && tar -czf "$W/control.tar.gz" ./control ./postinst ./postrm )
( cd "$W/data" && tar -czf "$W/data.tar.gz" ./usr )

# ar container (what dpkg reads): "!<arch>\n", then per member a 60-byte
# header (name 16, mtime 12, uid 6, gid 6, mode 8, size 10, "`\n"), data,
# and one "\n" of padding after an odd-sized member.
mt=$(date +%s)
member() { # NAME FILE
	sz=$(wc -c <"$2" | tr -d ' ')
	printf '%-16s%-12s%-6s%-6s%-8s%-10s`\n' "$1" "$mt" 0 0 100644 "$sz"
	cat "$2"
	[ $((sz % 2)) -eq 0 ] || printf '\n'
}
{
	printf '!<arch>\n'
	member debian-binary "$W/debian-binary"
	member control.tar.gz "$W/control.tar.gz"
	member data.tar.gz "$W/data.tar.gz"
} >"$OUT.tmp"
mv "$OUT.tmp" "$OUT"
chmod 644 "$OUT"
