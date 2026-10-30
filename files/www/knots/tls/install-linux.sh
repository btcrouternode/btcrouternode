#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Knots Appliance — trust local CA on Linux (N13 / U17)
#
# Typical steps after download (Downloads folder):
#   cd ~/Downloads   # or wherever the browser saved the file
#   chmod +x install-linux.sh
#   ./install-linux.sh
# Or without execute bit:
#   sh install-linux.sh
#
# Optional:  ./install-linux.sh http://rnode.local
#            ./install-linux.sh /path/to/knots-ca.crt
# The certificate is only installed if it is restricted to this router (P4).
# Prompts for your Linux user password (sudo). Firefox is closed if it is
# running (its store is locked), then reopened on HTTPS Setup (N13 / U17).

set -e

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Needs a controlling terminal for the sudo password — when launched from a
# file manager (double-click → "Run") there is none and sudo fails silently,
# which reads as "nothing happened". A pipe (wget … | sh) inside a terminal is
# fine: sudo asks on /dev/tty. Non-interactive sudo (scripts/tests) is allowed.
if ! (: </dev/tty) 2>/dev/null && ! sudo -n true 2>/dev/null; then
  echo "This installer must be run in a Terminal window — it needs to ask for"
  echo "your Linux login password (the one you use to log in to this computer;"
  echo "typing is invisible — that is normal)."
  echo ""
  echo "Open Terminal and run:"
  echo "  sh $0"
  echo ""
  # Keep a GUI-launched window readable before it closes.
  sleep 10
  exit 1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# Firefox (deb, snap, ESR) — process name is firefox / firefox-bin / firefox-esr.
firefox_is_running() {
  need_cmd pgrep || return 1
  pgrep -x firefox >/dev/null 2>&1 && return 0
  pgrep -x firefox-bin >/dev/null 2>&1 && return 0
  pgrep -x firefox-esr >/dev/null 2>&1 && return 0
  return 1
}

firefox_close() {
  pkill -x firefox 2>/dev/null || true
  pkill -x firefox-bin 2>/dev/null || true
  pkill -x firefox-esr 2>/dev/null || true
}

firefox_bin() {
  if need_cmd firefox; then
    command -v firefox
    return 0
  fi
  if [ -x /snap/bin/firefox ]; then
    echo /snap/bin/firefox
    return 0
  fi
  if need_cmd firefox-esr; then
    command -v firefox-esr
    return 0
  fi
  return 1
}

# Setup continues on HTTPS after trust (FIRST_RUN_UX page 2). Killing Firefox
# destroys the HTTP tab that would have soft-reloaded — reopen it here.
reopen_setup_https() {
  url="https://${HOST}/setup.html?after_tls=1"
  echo ""
  echo "Reopening Setup on ${url} …"

  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    if [ -S /tmp/.X11-unix/X0 ] || [ -d /tmp/.X11-unix ]; then
      DISPLAY=:0
      export DISPLAY
    fi
  fi

  if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo "No graphical session in this terminal — open this address:"
    echo "  ${url}"
    return 0
  fi

  # Profile lock can linger a moment after pkill.
  sleep 1

  ff=$(firefox_bin 2>/dev/null || true)
  if [ -n "$ff" ]; then
    nohup "$ff" --new-window "$url" >/dev/null 2>&1 &
    echo "Firefox is opening the secure Setup page."
    return 0
  fi
  if need_cmd xdg-open; then
    nohup xdg-open "$url" >/dev/null 2>&1 &
    echo "Opening the secure Setup page in your browser."
    return 0
  fi
  if need_cmd gio; then
    nohup gio open "$url" >/dev/null 2>&1 &
    echo "Opening the secure Setup page in your browser."
    return 0
  fi
  echo "Open this address in your browser:"
  echo "  ${url}"
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
ARG1="${1:-}"
CA_SRC=""
ROUTER="http://rnode.local"
# Per-run unique path: a fixed /tmp/knots-ca.crt is unwritable when a previous
# run (or another user) left one behind — Linux protected_sticky denies
# O_TRUNC on foreign files in sticky /tmp even to root.
CA=$(mktemp /tmp/knots-ca-XXXXXXXX.crt 2>/dev/null) || CA="/tmp/knots-ca.$$.crt"
chmod 644 "$CA" 2>/dev/null || true

# Argument: local .crt/.pem file, or router base URL
if [ -n "$ARG1" ]; then
  case "$ARG1" in
    *.crt|*.pem)
      [ -f "$ARG1" ] || die "CA file not found: $ARG1"
      CA_SRC=$ARG1
      ;;
    http://*|https://*)
      ROUTER=${ARG1%/}
      ;;
    *)
      die "Usage: $0 [http://rnode.local | /path/to/knots-ca.crt]"
      ;;
  esac
fi

download_ca() {
  if need_cmd curl; then
    curl -fsSL "${ROUTER}/knots-ca.crt" -o "$CA" 2>/dev/null
  elif need_cmd wget; then
    wget -q -O "$CA" "${ROUTER}/knots-ca.crt" 2>/dev/null
  else
    return 1
  fi
}

# P4 (review 2026-10-10): always fetch the router's CURRENT CA first. A copy
# left in Downloads from before a factory reset / Renew is a different CA and
# used to win, leaving the browser untrusted. Local files are only a fallback
# when the router cannot be reached (or an explicit .crt was given).
if [ -n "$CA_SRC" ]; then
  cp -f "$CA_SRC" "$CA"
else
  echo "Downloading CA from ${ROUTER}/knots-ca.crt ..."
  if ! download_ca; then
    for cand in \
      "$SCRIPT_DIR/knots-ca.crt" \
      "$HOME/Downloads/knots-ca.crt" \
      "$HOME/下载/knots-ca.crt"
    do
      if [ -f "$cand" ]; then
        CA_SRC=$cand
        echo "Router not reachable — using local copy: $CA_SRC"
        cp -f "$CA_SRC" "$CA"
        break
      fi
    done
    [ -n "$CA_SRC" ] || die "Could not download the certificate — stay on the router LAN (HTTP) and retry"
  fi
fi

# Sanity-check PEM
if ! grep -q "BEGIN CERTIFICATE" "$CA" 2>/dev/null; then
  die "Downloaded file does not look like a certificate: $CA"
fi
# P4 — only ever trust a CA that can vouch for this appliance and nothing
# else: subject "Knots Appliance CA", CA:TRUE, and CRITICAL nameConstraints
# limited to the appliance's names / private IPs (P3). A certificate swapped
# in on the network without those limits is refused, so it can never
# impersonate a bank or any other public site on this computer.
need_cmd openssl || die "openssl is required to check the certificate (sudo apt install openssl)"
ca_text=$(openssl x509 -in "$CA" -noout -text 2>/dev/null) || \
  die "openssl could not parse the CA — re-download knots-ca.crt over HTTP"
printf '%s\n' "$ca_text" | grep -q 'Subject: .*CN *= *Knots Appliance CA' || \
  die "This certificate is not a Knots Appliance CA — refusing to trust it"
printf '%s\n' "$ca_text" | grep -q 'CA:TRUE' || die "Not a CA certificate — refusing"
# Exactly the appliance's permitted set (same list as node-ui-tls.sh) — an
# attacker's CA permitting anything else (e.g. DNS:example.com) is refused.
want_nc='DNS:knots-router
DNS:lan
DNS:local
DNS:localhost
DNS:node-router
IP:10.0.0.0/255.0.0.0
IP:127.0.0.0/255.0.0.0
IP:172.16.0.0/255.240.0.0
IP:192.168.0.0/255.255.0.0'
got_nc=$(printf '%s\n' "$ca_text" | awk '/X509v3 Name Constraints: critical/{f=1;next} f&&/^ *(X509v3|Signature Algorithm|Authority Info)/{exit} f' \
  | sed -n -E 's/^ *((DNS|IP):[^ ,]*).*/\1/p' | sort -u)
if [ "$got_nc" != "$want_nc" ]; then
  echo "ERROR: this router's certificate is not restricted to the router itself." >&2
  echo "  Trusting it would let it vouch for other websites on this computer." >&2
  echo "  On the router: Settings → Renew HTTPS certificate, then run this again." >&2
  exit 1
fi
CA_FP=$(openssl x509 -in "$CA" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
echo "Certificate: Knots Appliance CA (restricted to this router)"
echo "  SHA-256 fingerprint: $CA_FP"
echo "  (Compare with Router Settings → HTTPS certificate on a device that already trusts it.)"

if need_cmd update-ca-certificates; then
  echo "Installing into system trust store (Debian/Ubuntu/… — sudo password)..."
  sudo mkdir -p /usr/local/share/ca-certificates
  sudo cp "$CA" /usr/local/share/ca-certificates/knots-ca.crt
  sudo chmod 644 /usr/local/share/ca-certificates/knots-ca.crt
  sudo update-ca-certificates
elif need_cmd update-ca-trust; then
  echo "Installing into system trust store (Fedora/RHEL/… — sudo password)..."
  sudo mkdir -p /etc/pki/ca-trust/source/anchors
  sudo cp "$CA" /etc/pki/ca-trust/source/anchors/knots-ca.crt
  sudo chmod 644 /etc/pki/ca-trust/source/anchors/knots-ca.crt
  sudo update-ca-trust extract 2>/dev/null || sudo update-ca-trust
elif need_cmd trust && [ -d /etc/ca-certificates/trust-source/anchors ]; then
  # Arch / some others
  echo "Installing into system trust store (Arch-style — sudo password)..."
  sudo mkdir -p /etc/ca-certificates/trust-source/anchors
  sudo cp "$CA" /etc/ca-certificates/trust-source/anchors/knots-ca.crt
  sudo trust extract-compat 2>/dev/null || sudo update-ca-trust 2>/dev/null || true
else
  echo "No system CA update tool found (update-ca-certificates / update-ca-trust)."
  echo "Import $CA into your browser certificate settings manually."
  exit 1
fi

HOST="${ROUTER#http://}"
HOST="${HOST#https://}"
HOST="${HOST%%/*}"
# wget|sh without a URL arg, or a local .crt: prefer the IUE name (U17).
case "$ARG1" in
  http://*|https://*) ;;
  *)
    if [ "$HOST" = "192.168.1.254" ] && getent hosts rnode.local >/dev/null 2>&1; then
      HOST=rnode.local
    fi
    ;;
esac
echo ""
echo "Done for the system certificate store."

# Firefox uses its own certificate store — import when certutil (NSS) is available
ff_imported=0
ff_running=0
ff_closed_by_us=0
if firefox_is_running; then
  ff_running=1
fi

# Firefox must be fully closed — its store is locked while running (U17).
if [ "$ff_running" = "1" ]; then
  echo ""
  echo "Firefox is running and locks its certificate store."
  echo "Closing Firefox gracefully in 5 seconds (tabs are restored next launch) — Ctrl-C to abort…"
  sleep 5
  firefox_close
  for i in $(seq 1 15); do
    firefox_is_running || break
    sleep 1
  done
  if firefox_is_running; then
    echo "  Firefox did not exit — please close it fully and re-run: $0"
  else
    ff_running=0
    ff_closed_by_us=1
    echo "  Firefox closed."
  fi
fi

# Ensure NSS certutil (the tool for Firefox's own store) — install if missing.
if ! need_cmd certutil && need_cmd apt-get; then
  echo "Installing NSS tools for Firefox's certificate store (sudo)…"
  sudo apt-get update -qq 2>/dev/null || true
  sudo apt-get install -y -qq libnss3-tools 2>/dev/null || true
fi

if need_cmd certutil && [ "$ff_running" = "0" ]; then
  for prof in \
    "$HOME"/.mozilla/firefox/*.default* \
    "$HOME"/snap/firefox/common/.mozilla/firefox/*.default* \
    "$HOME"/.var/app/org.mozilla.firefox/.mozilla/firefox/*.default*
  do
    [ -d "$prof" ] || continue
    if [ -f "$prof/cert9.db" ] || [ -f "$prof/cert8.db" ]; then
      echo "Importing CA into Firefox profile: $prof"
      certutil -d "sql:$prof" -D -n "Bitcoin Node CA" >/dev/null 2>&1 || true
      if certutil -d "sql:$prof" -A -t "C,," -n "Bitcoin Node CA" -i "$CA" 2>/dev/null; then
        ff_imported=1
        echo "  Firefox profile updated."
      else
        echo "  Could not write the Firefox store (Firefox must be FULLY closed first)."
      fi
    fi
  done
fi

# Closing Firefox destroys the HTTP Setup tab that would have switched to
# HTTPS by itself (FIRST_RUN_UX page 2). Reopen the same page on HTTPS.
if [ "$ff_closed_by_us" = "1" ]; then
  reopen_setup_https
else
  echo ""
  echo "If Setup is still open in this browser, it continues on HTTPS by itself."
  echo "If it does not, open: https://${HOST}/setup.html?after_tls=1"
fi
echo "  Setup checks BOTH https://${HOST}/ (Node Status) and https://${HOST}:8443/ (Router settings)."
echo "  If Router settings still warns: tap “I’ve finished — continue” on Setup."
echo "  (Browsers remember “risky site” separately for each port until the CA is trusted.)"
if [ "$ff_imported" = "0" ]; then
  echo ""
  echo "NOTE — Firefox uses its OWN certificate store (the system store above does not apply)."
  if [ "$ff_running" = "1" ]; then
    echo "  Firefox is RUNNING — its store is locked. Fully quit Firefox, then re-run:"
    echo "    $0"
    echo ""
  fi
  echo "To finish in Firefox, either:"
  echo "  a) install the NSS tools and re-run this script with Firefox fully closed:"
  echo "       sudo apt install -y libnss3-tools && $0"
  echo "  b) or import manually: Firefox → Settings → Privacy & Security → Certificates"
  echo "     → View Certificates → Authorities → Import → $CA"
  echo "     (tick “Trust this CA to identify websites”)."
  echo "Then fully quit Firefox before testing Router settings."
fi
