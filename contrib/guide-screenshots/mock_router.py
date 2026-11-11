#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Stand-in router for the user-guide screenshots (docs/USER_GUIDE.md).

Serves the router's real web UI (files/www/knots) and answers its API calls
from a scenario (JSON), so every screen can be shown in a chosen state without
a router. Plain HTTP on --http, HTTPS (self-signed, for pages that need it) on
--https. The capture script sets the scenario with POST /__scenario.

Nothing here runs on a router; it is a documentation tool only.
"""
import argparse, json, os, ssl, subprocess, sys, threading, urllib.parse
import http.server, socketserver

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WWW = os.path.join(ROOT, "files", "www", "knots")

DEFAULT = {
    "status": {
        "product_version": "25.0.32.0", "build_number": "122", "hostname": "node-router", "node_impl": "core",
        "maintenance": {"active": False, "op": "", "message": ""},
        "recovery": {"needs_reindex": False, "kind": "", "hint": ""},
        "knots": {"running": True, "verification_progress": 0.999998, "blocks": 925410, "headers": 925410,
                  "best_block_hash": "00000000000000000001a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7",
                  "peers": 10, "uptime_sec": 302400, "error": None},
        "storage": {"mounted": True, "path": "/mnt/bitcoin", "free_bytes": 1210000000000, "low_space": False},
        "disk": {"ok": True, "present": True, "level": "healthy", "reasons": [], "temp_c": 41, "percent_used": 3,
                 "model": "Samsung SSD 990 PRO 2TB", "power_loss_recent": False},
    },
    "setup": {
        "ok": True, "complete": False, "password_done": False, "locale_done": False, "wifi_staged": False,
        "lang": "en", "zonename": "Australia/Sydney", "country": "AU", "wifi_available": True, "client_wifi": False,
        "factory_labelled": True, "wifi_on": True, "node_impl": "core", "factory_reset_active": False,
        "factory_reset_live": False, "factory_reset_expected_seconds": 650, "upgrade_live": False,
        "upgrade_expected_seconds": 180, "upgrade_keep_config": True, "progress_step": "none", "progress_label": "",
        "wan": {"up": True, "proto": "dhcp", "ipv4": "100.64.12.34"},
        "lan": {"ipaddr": "192.168.1.254", "netmask": "255.255.255.0", "dhcp_start": "100", "dhcp_limit": "101"},
    },
    "settings": {
        "ok": True, "product_version": "25.0.32.0", "flash_id": "", "unit_name": "rnode-4216",
        "release_sig_required": True, "build_channel": "release", "conf_path": "/etc/bitcoin/bitcoin.conf",
        "conf_present": True, "upgrade": None,
        "ca_sha256": "3F:A1:7C:22:9B:0E:5D:41:C8:76:12:AF:E0:93:4B:6D:28:F5:01:BC:7A:3E:99:C4:58:0D:E2:16:7B:A9:44:C3",
        "ca_constrained": True, "node_running": True, "node_busy": False, "busy_message": "", "reindex_running": False,
        "last_op": None, "lang": "en", "upgrade_confirm": "UPGRADE", "save_confirm": "SAVE",
        "advanced_confirm": "ADVANCED", "language_confirm": "LANGUAGE", "stop_confirm": "STOP",
        "start_confirm": "START", "reboot_confirm": "REBOOT", "shutdown_confirm": "SHUTDOWN",
        "factory_reset_confirm": "RESET", "factory_reset_expected_seconds": 650, "factory_reset_active": False,
        "factory_reset_live": False, "upgrade_live": False, "upgrade_expected_seconds": 300,
        "upgrade_keep_config": True, "progress_step": "none", "progress_label": "", "note": "",
    },
    "node": {"ok": True, "active": "core", "default": "core",
             "knots": {"installed": False, "version": "", "prev_available": False, "prev_version": ""},
             "core": {"installed": True, "version": "32.1", "prev_available": False, "prev_version": ""},
             "running": True, "datadir": "/mnt/bitcoin", "binroot": "/mnt/bitcoin/node-bin",
             "wallet_present": False, "wallets": "", "note": "", "last_op": None},
    "conf": {"ok": True,
             "safe": {"dbcache": 1024, "maxconnections": 125, "maxmempool": 300, "mempoolexpiry": 336,
                      "blocksonly": 0, "peerbloomfilters": 0},
             "raw": "prune=0\ndisablewallet=1\ntxindex=0\nlisten=1\nserver=1\nport=8333\nrpcport=8332\n"
                    "listenonion=0\nbind=21.21.21.21\nbind=[fd21:21:21::21]\nrpcbind=21.21.21.21\n"
                    "rpcallowip=21.21.21.0/24\nrpcauth=<hidden>\ndbcache=1024\nmaxconnections=125\nnatpmp=0\n"
                    "datadir=/mnt/bitcoin\npid=/run/bitcoind.pid\n"},
    "ui_lang": "en",
    "post": {},          # "/api/setup?action=quickstart": {...} — default {"ok": true}
    "delay_ms": {},      # per path prefix, e.g. slow answers for "working…" screens
}

STATE = json.loads(json.dumps(DEFAULT))
LOCK = threading.Lock()


def merge(a, b):
    for k, v in b.items():
        if isinstance(v, dict) and isinstance(a.get(k), dict) and k not in ("post",):
            merge(a[k], v)
        else:
            a[k] = v


class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=WWW, **kw)

    def log_message(self, *a):
        pass

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def _json(self, obj, code=200):
        b = (obj if isinstance(obj, str) else json.dumps(obj)).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _api(self, method):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        action = (q.get("action") or [""])[0]
        key = u.path + ("?action=" + action if action else "")
        with LOCK:
            st = json.loads(json.dumps(STATE))
        for pfx, ms in st["delay_ms"].items():
            if key.startswith(pfx):
                import time; time.sleep(ms / 1000)
        if key in st["post"]:
            r = st["post"][key]
            return self._json(r.get("body", r), r.get("code", 200) if isinstance(r, dict) else 200)
        if u.path == "/api/alive":
            return self._json({"ok": True, "alive": True})
        if u.path == "/api/status":
            return self._json(st["status"])
        if u.path == "/api/setup" and action == "wan_status":
            return self._json(dict({"ok": True}, **st["setup"]["wan"]))
        if u.path == "/api/setup" and action in ("status", ""):
            return self._json(st["setup"])
        if u.path == "/api/settings" and action == "status":
            return self._json(st["settings"])
        if u.path == "/api/settings" and action == "conf":
            return self._json(st["conf"])
        if u.path == "/api/node" and action in ("status", ""):
            return self._json(st["node"])
        return self._json({"ok": True})

    def do_GET(self):
        p = urllib.parse.urlparse(self.path).path
        if p.startswith("/api/"):
            return self._api("GET")
        if p == "/ui-lang":
            b = STATE["ui_lang"].encode()
            self.send_response(200); self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
            return
        if p == "/knots-ca.crt":
            return self._json("-----BEGIN CERTIFICATE-----\n(sample)\n-----END CERTIFICATE-----\n")
        if p == "/":
            self.path = "/index.html"
        if p == "/luci-entry.html":                     # LuCI's entry page lives one level up
            b = open(os.path.join(os.path.dirname(WWW), "luci-entry.html"), "rb").read()
            self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
            return
        return super().do_GET()

    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        if p == "/__scenario":
            sc = json.loads(body or b"{}")
            with LOCK:
                STATE.clear(); STATE.update(json.loads(json.dumps(DEFAULT)))
                merge(STATE, sc)
            return self._json({"ok": True})
        return self._api("POST")


class Srv(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--http", type=int, default=18080)
    ap.add_argument("--https", type=int, default=18443)
    ap.add_argument("--workdir", required=True)
    a = ap.parse_args()
    os.makedirs(a.workdir, exist_ok=True)
    crt, key = os.path.join(a.workdir, "mock.crt"), os.path.join(a.workdir, "mock.key")
    if not os.path.exists(crt):
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "30", "-subj",
                        "/CN=localhost", "-keyout", key, "-out", crt], check=True, capture_output=True)
    s1 = Srv(("127.0.0.1", a.http), H)
    s2 = Srv(("127.0.0.1", a.https), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(crt, key)
    s2.socket = ctx.wrap_socket(s2.socket, server_side=True)
    threading.Thread(target=s2.serve_forever, daemon=True).start()
    print(f"mock router: http://127.0.0.1:{a.http}/  https://127.0.0.1:{a.https}/", flush=True)
    s1.serve_forever()


if __name__ == "__main__":
    main()
