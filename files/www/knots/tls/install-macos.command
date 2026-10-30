#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# RNode — trust this router's certificate on a Mac (N13 / U17)
#
# Setup's Mac path (owner decision 2026-10-25): no profile, no download to
# approve, no developer signing. Setup shows ONE Terminal command:
#   f=$(mktemp) && curl -fsSL http://rnode-xxxx.local/tls/install-macos.command -o "$f" && bash "$f" http://rnode-xxxx.local
# (curl does not quarantine, so Gatekeeper never blocks it.) The certificate
# goes into this Mac user's own trust settings: macOS shows its normal
# password box once ("…make changes to your Certificate Trust Settings").
# Safari, Chrome and Edge use these settings; Firefox imports them.

set -e

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
ARG1="${1:-}"
CA_SRC=""
ROUTER="http://rnode.local"
# P4/W13: private per-run temp file — a fixed /tmp path could be pre-created
# by another local user and swapped before `security add-trusted-cert` reads it.
CA=$(mktemp "${TMPDIR:-/tmp}/knots-ca.XXXXXXXX") || die "mktemp failed"
trap 'rm -f "$CA"' EXIT

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

# P4: fetch the router's CURRENT CA first; a copy left in Downloads from
# before a factory reset / Renew is a different CA. Local files = fallback.
if [ -n "$CA_SRC" ]; then
  cp -f "$CA_SRC" "$CA"
else
  echo "Downloading CA from ${ROUTER}/knots-ca.crt ..."
  if ! curl -fsSL "${ROUTER}/knots-ca.crt" -o "$CA" 2>/dev/null; then
    for cand in "$SCRIPT_DIR/knots-ca.crt" "$HOME/Downloads/knots-ca.crt"; do
      if [ -f "$cand" ]; then
        CA_SRC=$cand
        echo "Router not reachable — using local copy: $CA_SRC"
        cp -f "$CA_SRC" "$CA"
        break
      fi
    done
    [ -n "$CA_SRC" ] || die "Download failed — use HTTP on the router LAN"
  fi
fi

grep -q "BEGIN CERTIFICATE" "$CA" || die "File is not a certificate"
ca_text=$(openssl x509 -in "$CA" -noout -text 2>/dev/null) || die "Invalid certificate file"

# P4 — only trust a CA restricted to this appliance (P3 nameConstraints, the
# exact permitted set); anything else could vouch for other websites.
printf '%s\n' "$ca_text" | grep -q 'Subject: .*CN *= *Knots Appliance CA' || \
  die "This certificate is not a Knots Appliance CA — refusing to trust it"
printf '%s\n' "$ca_text" | grep -q 'CA:TRUE' || die "Not a CA certificate — refusing"
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
  echo "  On the router: Settings → Renew HTTPS certificate, then run this again." >&2
  exit 1
fi
echo "Certificate: Knots Appliance CA (restricted to this router)"
echo "  SHA-256 fingerprint: $(openssl x509 -in "$CA" -noout -fingerprint -sha256 | cut -d= -f2)"
echo "  (Compare with Router Settings → HTTPS certificate on a device that already trusts it.)"

echo ""
echo "Your Mac will now ask for your password (to trust this router's certificate)."
KC="$HOME/Library/Keychains/login.keychain-db"
[ -f "$KC" ] || KC="$HOME/Library/Keychains/login.keychain"
security add-trusted-cert -r trustRoot -k "$KC" "$CA" \
  || die "The certificate was not trusted (password box cancelled?). Run the command again."

HOST="${ROUTER#http://}"
HOST="${HOST#https://}"
echo ""
echo "Done — this Mac now trusts the router. Opening the secure Setup page…"
echo "  (Router settings at https://${HOST}:8443/ use the same certificate.)"
open "https://${HOST}/setup.html?after_tls=1" 2>/dev/null || true
echo "You can close this Terminal window."
