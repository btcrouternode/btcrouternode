#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Laptop web UAT for the BPI-R4 Knots appliance (Phase 2 Node SKU).

IUE (Quick/Guided) is clicked in Chromium the same way a person uses Setup
(Welcome → Security → choice → fields → Finish). Other phases still use the
HTTP APIs Settings/Node already call. Waits through factory reset and both
upgrades. Does not flash SD/eMMC and does not wipe M.2.
"""

from __future__ import annotations

import http.cookiejar
import json
import os
import ssl
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))
from uat_wizard import GUIDED_DHCP_START, GUIDED_SSID, with_wizard  # noqa: E402

# P1: a labelled router's factory admin password is its per-device label
# secret; unlabelled routers keep the legacy password (Wi-Fi off pre-Setup).
LEGACY_FACTORY_PASS = "knotsnode21"
FACTORY_PASS = os.environ.get("KNOTS_UAT_FACTORY_PASS", LEGACY_FACTORY_PASS)
EXPECT_LABELLED = FACTORY_PASS != LEGACY_FACTORY_PASS
FACTORY_SSID = "rnode"
QUICK_PASS = "uattest99"
GUIDED_PASS = "uattest88"
UAT_WIFI = "uattestwifi99"
PHASES = [
    "pages",
    "status",
    "nav",
    "security",
    "settings",
    "node",
    "luci",
    "ui",
    "reboot",
    "upgrade_keep",
    "release_sig",
    "factory",
    "iue_quick",
    "upgrade_reset",
    "iue_guided",
]


def env(name: str, default: str) -> str:
    return os.environ.get(name, default)


HOST = env("KNOTS_UAT_HOST", "192.168.1.254")
USER = env("KNOTS_UAT_USER", "root")
PASS = env("KNOTS_UAT_PASS", FACTORY_PASS)
DOCS = Path(env("KNOTS_UAT_DOCS", str(Path.home() / "Documents")))
SSL_CTX = ssl._create_unverified_context()
_COOKIES = http.cookiejar.CookieJar()


class _KeepPostRedirect(urllib.request.HTTPRedirectHandler):
    """Do not turn POST into GET on 302 (nginx HTTP→HTTPS would then hit CGI as GET)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if req.get_method() == "POST" and code in (301, 302, 303, 307, 308):
            return None
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=SSL_CTX),
    urllib.request.HTTPCookieProcessor(_COOKIES),
    _KeepPostRedirect(),
)
urllib.request.install_opener(_OPENER)
FAILS: list[str] = []
RESULTS: list[dict[str, Any]] = []
SUITE_DIR = Path(__file__).resolve().parent
RESULTS_DIR = Path(env("KNOTS_UAT_RESULTS", str(SUITE_DIR / "results")))
_LOG_FH: IO[str] | None = None
_RUN_ID = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
_STARTED = datetime.now(timezone.utc)
_LOG_PATH: Path | None = None
_JSON_PATH: Path | None = None


def log(msg: str) -> None:
    print(msg, flush=True)
    if _LOG_FH is not None:
        _LOG_FH.write(msg + "\n")
        _LOG_FH.flush()


def ok(tc: str, name: str, cond: bool, detail: str = "") -> bool:
    line = ("PASS" if cond else "FAIL") + f" [{tc}] {name}"
    if detail and not cond:
        line += f" — {detail}"
    log(line)
    RESULTS.append(
        {
            "id": tc,
            "name": name,
            "pass": bool(cond),
            "detail": detail,
            "ts": datetime.now(timezone.utc).isoformat(),
        }
    )
    if not cond:
        FAILS.append(f"{tc} {name}")
    return bool(cond)


def _open_run_log() -> None:
    global _LOG_FH, _LOG_PATH, _JSON_PATH
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    _LOG_PATH = RESULTS_DIR / f"uat-{_RUN_ID}.log"
    _JSON_PATH = RESULTS_DIR / f"uat-{_RUN_ID}.json"
    _LOG_FH = _LOG_PATH.open("w", encoding="utf-8")
    for name in ("last-run.log", "last-run.json"):
        link = RESULTS_DIR / name
        try:
            if link.exists() or link.is_symlink():
                link.unlink()
        except OSError:
            pass
    try:
        (RESULTS_DIR / "last-run.log").symlink_to(_LOG_PATH.name)
        (RESULTS_DIR / "last-run.json").symlink_to(_JSON_PATH.name)
    except OSError:
        pass


def write_summary(exit_code: int, extra: dict[str, Any] | None = None) -> None:
    payload = {
        "run_id": _RUN_ID,
        "started": _STARTED.isoformat(),
        "ended": datetime.now(timezone.utc).isoformat(),
        "elapsed_sec": int(time.time() - _STARTED.timestamp()),
        "exit_code": exit_code,
        "host": HOST,
        "user": USER,
        "password_at_end": R.password,
        "passed": sum(1 for r in RESULTS if r["pass"]),
        "failed": len(FAILS),
        "checks": len(RESULTS),
        "failed_ids": list(FAILS),
        "results": RESULTS,
    }
    if extra:
        payload.update(extra)
    text = json.dumps(payload, indent=2) + "\n"
    if _JSON_PATH is not None:
        _JSON_PATH.write_text(text, encoding="utf-8")
    last_json = RESULTS_DIR / "last-run.json"
    if not last_json.is_symlink():
        last_json.write_text(text, encoding="utf-8")
    if _LOG_PATH is not None:
        last_log = RESULTS_DIR / "last-run.log"
        if not last_log.is_symlink():
            last_log.write_text(_LOG_PATH.read_text(encoding="utf-8"), encoding="utf-8")
    log(f"Results log: {_LOG_PATH}")
    log(f"Results json: {_JSON_PATH}")


class Router:
    """HTTP/HTTPS client for the Knots UI and CGI APIs the browser uses."""

    def __init__(self, host: str) -> None:
        self.host = host
        self.password = PASS

    def url(self, path: str, https: bool = False, port: int | None = None) -> str:
        scheme = "https" if https else "http"
        p = port if port is not None else (443 if https else 80)
        if (https and p == 443) or (not https and p == 80):
            return f"{scheme}://{self.host}{path}"
        return f"{scheme}://{self.host}:{p}{path}"

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        data: bytes | None = None,
        headers: dict[str, str] | None = None,
        https: bool = False,
        port: int | None = None,
        timeout: float = 45,
        query: dict[str, str] | None = None,
    ) -> tuple[int, dict[str, str], bytes]:
        url = self.url(path, https=https, port=port)
        if query:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(query)
        hdrs = {"Cache-Control": "no-store", "Connection": "close"}
        if headers:
            hdrs.update(headers)
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                body = resp.read()
                return int(resp.status), dict(resp.headers.items()), body
        except urllib.error.HTTPError as exc:
            body = exc.read() if exc.fp else b""
            return int(exc.code), dict(exc.headers.items()) if exc.headers else {}, body
        except Exception as exc:
            raise ConnectionError(f"{method} {url}: {exc}") from exc

    def get_text(self, path: str, **kw: Any) -> tuple[int, str]:
        code, _hdrs, body = self.request(path, **kw)
        return code, body.decode("utf-8", "replace")

    def get_json(self, path: str, **kw: Any) -> tuple[int, dict[str, Any]]:
        code, _hdrs, body = self.request(path, **kw)
        text = body.decode("utf-8", "replace")
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return code, {"ok": False, "error": "not_json", "raw": text[:240]}
        if not isinstance(data, dict):
            return code, {"ok": False, "error": "not_object", "raw": text[:240]}
        return code, data

    def post_form(
        self, path: str, fields: dict[str, str], **kw: Any
    ) -> tuple[int, dict[str, Any]]:
        body = urllib.parse.urlencode(fields).encode()
        hdrs = {"Content-Type": "application/x-www-form-urlencoded"}
        code, _h, raw = self.request(
            path, method="POST", data=body, headers=hdrs, **kw
        )
        text = raw.decode("utf-8", "replace")
        try:
            data = json.loads(text)
        except json.JSONDecodeError:
            return code, {
                "ok": False,
                "error": "not_json",
                "raw": text[:240],
                "http": code,
            }
        if not isinstance(data, dict):
            return code, {"ok": False, "error": "not_object"}
        return code, data

    def post_api(self, path: str, fields: dict[str, str]) -> dict[str, Any]:
        last: dict[str, Any] = {}
        for https in (True, False):
            try:
                _code, data = self.post_form(
                    path, fields, https=https, timeout=60
                )
            except ConnectionError:
                continue
            last = data
            if data.get("ok") or data.get("error") not in ("not_json", "method"):
                return data
            if data.get("error") == "method":
                continue
        return last or {"ok": False, "error": "unreachable"}

    def settings(self, action: str, extra: dict[str, str] | None = None) -> dict[str, Any]:
        fields = {"action": action, "user": USER, "password": self.password}
        if extra:
            fields.update(extra)
        return self.post_api(f"/api/settings?action={action}", fields)

    def setup(self, action: str, extra: dict[str, str] | None = None) -> dict[str, Any]:
        fields = {"action": action}
        if extra:
            fields.update(extra)
        _code, data = self.post_form(f"/api/setup?action={action}", fields)
        return data

    def node(self, action: str, extra: dict[str, str] | None = None) -> dict[str, Any]:
        fields = {"action": action, "user": USER, "password": self.password}
        if extra:
            fields.update(extra)
        return self.post_api(f"/api/node?action={action}", fields)

    def setup_status(self) -> dict[str, Any]:
        for https in (False, True):
            try:
                _code, data = self.get_json("/api/setup?action=status", https=https)
                if data.get("ok"):
                    return data
            except ConnectionError:
                continue
        return {}

    def settings_status(self) -> dict[str, Any]:
        for https in (True, False):
            try:
                _code, data = self.get_json("/api/settings?action=status", https=https)
                if data.get("ok"):
                    return data
            except ConnectionError:
                continue
        return {}

    def api_status(self) -> dict[str, Any]:
        for https in (True, False):
            try:
                _code, data = self.get_json("/api/status", https=https)
                if "product_version" in data or data.get("ok"):
                    return data
            except ConnectionError:
                continue
        return {}

    def page_title(self, html: str) -> str:
        low = html.lower()
        i = low.find("<title>")
        j = low.find("</title>")
        if i >= 0 and j > i:
            return html[i + 7 : j].strip()
        return ""


R = Router(HOST)


def discover_password() -> None:
    """Use whatever password the last UAT/IUE left on the box (or factory)."""
    seen: list[str] = []
    for candidate in (PASS, GUIDED_PASS, QUICK_PASS, FACTORY_PASS):
        if candidate in seen:
            continue
        seen.append(candidate)
        R.password = candidate
        out = R.settings("locale", {"confirm": "NO", "lang": "en"})
        err = str(out.get("error") or "")
        if err == "auth_failed":
            continue
        if err == "confirm_required" or out.get("ok"):
            log("Authenticated (router password is a known UAT/factory value)")
            return
    raise SystemExit(
        "cannot authenticate as root — tried factory and last UAT passwords"
    )


def wait_until(
    name: str,
    pred: Callable[[], bool],
    timeout: float,
    interval: float = 5.0,
) -> bool:
    end = time.time() + timeout
    last = "not started"
    while time.time() < end:
        try:
            if pred():
                log(f"  .. {name}: ready")
                return True
            last = "predicate false"
        except ConnectionError as exc:
            last = str(exc)
        except Exception as exc:
            last = str(exc)
        time.sleep(interval)
    log(f"  .. {name}: timeout after {int(timeout)}s ({last})")
    return False


def fail_detail(data: dict[str, Any]) -> str:
    parts = [
        str(data.get("message") or ""),
        str(data.get("error") or ""),
        str(data.get("raw") or ""),
        f"http {data['http']}" if "http" in data else "",
    ]
    return " ".join(p for p in parts if p)[:240] or str(data)[:240]


def _iue_shots(tag: str) -> Path:
    return RESULTS_DIR / "shots" / f"{_RUN_ID}-{tag}"


def _verdict(cid: str, op: str) -> None:
    """L2: the detached worker's own verdict (status.last_op) must be ok."""
    def _done() -> bool:
        lo = R.settings_status().get("last_op") or {}
        return lo.get("op") == op and lo.get("state") in ("ok", "failed")
    wait_until(f"{op} verdict", _done, timeout=180, interval=3)
    lo = R.settings_status().get("last_op") or {}
    ok(cid, f"{op} worker verdict ok (L2)", lo.get("op") == op and lo.get("state") == "ok",
       f"{lo.get('state')}: {lo.get('message')}")


def wait_node_running(want: bool, timeout: float = 180) -> bool:
    # L1 (review 2026-10-10): node_running flips while a detached restart /
    # stop worker is still working; also wait for node_busy to clear, or the
    # next node action races that worker (seen on .78: SET-6/7).
    def pred() -> bool:
        st = R.settings_status()
        return st.get("node_running") is want and not st.get("node_busy")

    return wait_until(f"node_running={want}", pred, timeout=timeout, interval=3)


def reachable() -> bool:
    try:
        code, _ = R.get_text("/", timeout=8)
        return code in (200, 302)
    except ConnectionError:
        return False


def html_has(path: str, needle: str, **kw: Any) -> bool:
    try:
        _code, text = R.get_text(path, **kw)
    except ConnectionError:
        return False
    return needle in text


def find_image() -> tuple[Path, str]:
    explicit = env("KNOTS_UAT_IMAGE", "")
    if explicit:
        path = Path(explicit).expanduser()
    else:
        cands = sorted(
            DOCS.glob("*sysupgrade.itb"),
            key=lambda p: p.stat().st_mtime,
            reverse=True,
        )
        path = cands[0] if cands else Path()
    if not path.is_file():
        raise FileNotFoundError(
            f"No *sysupgrade.itb in {DOCS} (set KNOTS_UAT_IMAGE)"
        )
    sha = env("KNOTS_UAT_SHA256", "")
    if not sha:
        for sib in (
            path.with_suffix(".sha256"),
            path.parent / (path.name.replace("-squashfs-sysupgrade.itb", ".sha256")),
            path.parent / f"{path.name}.sha256",
        ):
            if sib.is_file():
                sha = sib.read_text(encoding="utf-8").split()[0]
                break
    sha = sha.strip().lower()
    if len(sha) != 64:
        raise ValueError(f"Need 64-hex SHA256 for {path.name} (KNOTS_UAT_SHA256)")
    return path, sha


def phase_pages() -> None:
    # .98: once Setup is complete /setup.html opens Node Status (not the wizard)
    done = R.setup_status().get("complete") is True
    pages = [
        ("UAT-P-1", "/", "shell.js", False),
        ("UAT-P-2", "/index.html", "shell.js", False),
        ("UAT-P-3", "/node.html", "Node software", False),
        ("UAT-P-4", "/settings.html", "btnFactoryReset", False),
        ("UAT-P-5", "/setup.html", "shell.js" if done else "Welcome to RNode", False),
        ("UAT-P-6", "/reset.html", "Factory Reset in Progress", False),
        ("UAT-P-7", "/upgrade.html", "Firmware Update in Progress", False),
        ("UAT-P-8", "/tls.html", "install", False),
    ]
    for tc, path, needle, https in pages:
        try:
            code, text = R.get_text(path, https=https, timeout=12)
            ok(tc, f"GET {path}", code == 200 and needle in text, f"HTTP {code}")
        except ConnectionError as exc:
            ok(tc, f"GET {path}", False, str(exc))
    try:
        code, text = R.get_text("/", port=8080, timeout=12)
        ok(
            "UAT-P-9",
            "LuCI chooser",
            code in (200, 302)
            and ("Back to Node Status" in text or "Node Dashboard" in text or "LuCI" in text),
            f"HTTP {code}",
        )
    except ConnectionError as exc:
        ok("UAT-P-9", "LuCI chooser", False, str(exc))
    for tc, path, needle in (
        ("UAT-P-10", "/knots-ca.crt", "BEGIN CERTIFICATE"),
        ("UAT-P-11", "/tls/install-linux.sh", "#!/"),
        ("UAT-P-12", "/i18n/en.json", "{"),
    ):
        try:
            code, text = R.get_text(path, timeout=12)
            ok(tc, f"GET {path}", code == 200 and needle in text, f"HTTP {code}")
        except ConnectionError as exc:
            ok(tc, f"GET {path}", False, str(exc))
    try:
        code, text = R.get_text("/storage.html", timeout=8)
        wipe = "storage-wipe" in text or "Wipe M.2" in text or "wipe the blockchain" in text.lower()
        ok(
            "UAT-P-13",
            "no storage wipe page",
            (code in (404, 302) or code == 200) and not wipe,
            f"HTTP {code}",
        )
    except ConnectionError:
        ok("UAT-P-13", "no storage wipe page", True)


def phase_status() -> None:
    st = R.api_status()
    ok("UAT-S-1", "/api/status has product_version", bool(st.get("product_version")), str(st)[:160])
    if st.get("product_version"):
        log(f"  .. product_version={st.get('product_version')}")
    knots = st.get("knots") if isinstance(st.get("knots"), dict) else st
    ok(
        "UAT-S-4",
        "Node Status has blocks/peers (U2)",
        "blocks" in str(st) and ("peers" in str(st) or "peer" in str(st).lower()),
        str(knots)[:160] if knots else str(st)[:160],
    )
    # M.2 drive health (disk-health.sh, every 5 min): present, SMART read,
    # temperature and wear reported, not failed. Right after a boot the first
    # result can take one status-loop pass; wait up to 2 min for it.
    disk = st.get("disk") or {}
    if not disk:
        def _disk() -> bool:
            nonlocal disk
            disk = R.api_status().get("disk") or {}
            return bool(disk)
        wait_until("disk health reported", _disk, timeout=120, interval=10)
    ok("UAT-DH-1", "M.2 drive health reported (present, SMART, temperature, wear)",
       disk.get("present") is True and disk.get("smart") is True
       and isinstance(disk.get("temp_c"), int) and isinstance(disk.get("percent_used"), int),
       str({k: disk.get(k) for k in ("level", "reasons", "temp_c", "percent_used", "model")})[:200])
    ok("UAT-DH-2", "M.2 drive not failed / at risk", disk.get("level") in ("healthy", "attention"),
       f"{disk.get('level')} {disk.get('reasons')}")
    ss = R.settings_status()
    ok("UAT-S-2", "Settings status", bool(ss.get("ok")), str(ss.get("error") or ss)[:160])
    if "ca_sha256" in ss:
        # P4: Settings (trusted HTTPS) shows the CA fingerprint users compare
        # with the installer's output; it must be the CA actually served.
        served = _ca_fp(_ca_pem()).upper()
        shown = str(ss.get("ca_sha256") or "").replace(":", "").upper()
        ok("UAT-S-6", "Settings CA fingerprint = served knots-ca.crt; restricted (P4/P3)",
           bool(served) and shown == served and ss.get("ca_constrained") is True,
           f"shown={shown[:16]} served={served[:16]} constrained={ss.get('ca_constrained')}")
    # N20: unique unit name, and the HTTPS leaf is valid for it
    unit = str(R.settings_status().get("unit_name") or "")
    import re as _re
    ok("UAT-N20-1", "Settings reports the unit name rnode-XXXX", bool(_re.fullmatch(r"rnode-[0-9a-f]{4}", unit)), unit)
    if unit:
        try:
            import socket, ssl as _ssl
            ctx = _ssl.create_default_context(cadata=_ca_pem())
            with socket.create_connection((HOST, 443), timeout=10) as raw:
                with ctx.wrap_socket(raw, server_hostname=f"{unit}.local"):
                    pass
            ok("UAT-N20-2", f"HTTPS certificate valid for {unit}.local", True)
        except Exception as exc:
            ok("UAT-N20-2", f"HTTPS certificate valid for {unit}.local", False, str(exc)[:200])
        # .103 field find: the name was never announced (avahi "Local name
        # collision"). Resolve it like a laptop does (nss-mdns), up to 60 s.
        import socket
        got = ""
        for _ in range(12):
            try:
                got = socket.getaddrinfo(f"{unit}.local", 80, socket.AF_INET)[0][4][0]
                break
            except OSError as exc:
                got = str(exc)
                time.sleep(5)
        ok("UAT-N20-3", f"{unit}.local resolves on the LAN (mDNS) to the router", got == HOST, got)
    su = R.setup_status()
    ok("UAT-S-3", "Setup status", bool(su.get("ok")), str(su.get("error") or su)[:160])
    if "factory_labelled" in su:
        ok(
            "UAT-S-5",
            f"factory_labelled={EXPECT_LABELLED} (P1 per-device secret {'provisioned' if EXPECT_LABELLED else 'absent'})",
            su.get("factory_labelled") is EXPECT_LABELLED,
            f"router says {su.get('factory_labelled')}",
        )
    if su:
        log(f"  .. setup complete={su.get('complete')} factory_reset_live={su.get('factory_reset_live')}")


def phase_nav() -> None:
    js = ""
    try:
        _code, js = R.get_text("/shell.js")
    except ConnectionError:
        js = ""
    ok("UAT-N-1", "shell.js served", "nav.status" in js or "Node Status" in js, js[:80])
    try:
        _c, html = R.get_text("/index.html")
    except ConnectionError:
        html = ""
    ok("UAT-N-2", "Node Status chrome", "shell.js" in html or "nav-item" in html)
    ok("UAT-N-3", "no Wallet nav", "Wallet" not in html or 'label: "Wallet"' not in html)
    try:
        _c, node = R.get_text("/node.html")
        ok("UAT-N-4", "Node software page", "Node software" in node or "node-impl" in node.lower() or "Bitcoin" in node)
        ok("UAT-N-5", "no Storage wipe on node page", "storage-wipe" not in node)
    except ConnectionError as exc:
        ok("UAT-N-4", "Node software page", False, str(exc))
        ok("UAT-N-5", "no Storage wipe on node page", False, str(exc))
    try:
        _c, settings = R.get_text("/settings.html")
        for tc, needle, name in (
            ("UAT-N-6", "btnFactoryReset", "Factory Reset control"),
            ("UAT-N-7", "UPGRADE", "Upgrade confirm"),
            ("UAT-N-8", "startReindex", "ReIndex control"),
            ("UAT-N-9", "REBOOT", "Reboot control"),
        ):
            ok(tc, name, needle in settings)
        ok("UAT-N-10", "no Lightning tab", "Lightning" not in settings)
    except ConnectionError as exc:
        ok("UAT-N-6", "settings.html", False, str(exc))


def phase_security() -> None:
    """Review S1/S2/S3 (2026-10-10). Every probe here is refused by design;
    nothing on the router changes."""
    evil = "https://evil.example"

    def hdr(h: dict[str, str], name: str) -> str:
        for k, v in h.items():
            if k.lower() == name.lower():
                return v
        return ""

    for https in (False, True):
        tag = "443" if https else "80"
        try:
            code, _h, _b = R.request("/api/alive", https=https, headers={"Host": "evil.example"}, timeout=12)
        except ConnectionError as exc:
            code = str(exc)
        ok(f"UAT-SEC-HOST-{tag}", f"foreign Host refused on :{tag} (DNS rebinding)", code == 421, str(code))

    # D2/H3 (review 2026-10-11): redirects keep the host the browser used —
    # by IP (no mDNS) the router must not bounce the client to rnode.local.
    import http.client

    def location_for(host_hdr: str) -> str:
        c = http.client.HTTPConnection(HOST, 8080, timeout=12)
        try:
            c.request("GET", "/", headers={"Host": host_hdr, "Connection": "close"})
            r = c.getresponse()
            return r.getheader("Location") or f"(HTTP {r.status})"
        except OSError as exc:
            return f"({exc})"
        finally:
            c.close()

    loc_ip = location_for(HOST)
    ok("UAT-D2-1", "LuCI :8080 by IP redirects to the same IP (D2)",
       loc_ip.startswith(f"https://{HOST}:8443"), loc_ip)
    loc_name = location_for("rnode.local")
    ok("UAT-D2-2", "LuCI :8080 by rnode.local stays on rnode.local (D2)",
       loc_name.startswith("https://rnode.local:8443"), loc_name)

    code, _h, _b = R.request(
        "/api/setup?action=password", method="POST", data=b"password=x&password2=x",
        headers={"Origin": evil, "Content-Type": "application/x-www-form-urlencoded"}, timeout=12,
    )
    ok("UAT-SEC-CSRF-1", "cross-site POST to Setup refused", code == 403, str(code))
    code, _h, _b = R.request(
        "/api/settings?action=reboot", method="POST", data=b"confirm=REBOOT",
        headers={"Origin": evil, "Content-Type": "application/x-www-form-urlencoded"},
        https=True, timeout=12,
    )
    ok("UAT-SEC-CSRF-2", "cross-site POST to Settings refused", code == 403, str(code))
    code, _h, _b = R.request("/api/settings?action=status", headers={"Origin": "null"}, timeout=12)
    ok("UAT-SEC-CSRF-3", "Origin: null refused", code == 403, str(code))

    _c, data = R.get_json("/api/setup?action=password&password=x&password2=x", timeout=12)
    ok(
        "UAT-SEC-GET",
        "GET cannot run a Setup mutation",
        data.get("ok") is False and data.get("error") in ("method", "setup_complete"),
        str(data)[:160],
    )
    # .97 field report: a bookmarked / restored https Setup page after Setup
    # ran a wizard against the locked API (raw nginx 404). It must land on
    # Node Status instead, from https and from http.
    if R.setup_status().get("complete") is True:
        for https in (True, False):
            try:
                code, _h, body = R.request("/setup.html?after_tls=1", https=https, timeout=15)
                good = code == 200 and b"setup.js" not in body
                detail = f"HTTP {code}, {'wizard' if b'setup.js' in body else 'not the wizard'}"
            except ConnectionError as exc:
                good, detail = False, str(exc)[:160]
            ok(f"UAT-SEC-SETUP-DONE-{'443' if https else '80'}",
               f"Setup page after Setup opens Node Status, not the wizard ({'https' if https else 'http'})",
               good, detail)

    same = f"http://{R.host}"
    code, h, _b = R.request("/api/alive", headers={"Origin": same}, timeout=12)
    ok("UAT-SEC-CORS-1", "same-appliance Origin echoed on /api/alive",
       code == 200 and hdr(h, "Access-Control-Allow-Origin") == same,
       f"{code} {hdr(h, 'Access-Control-Allow-Origin')!r}")
    code, h, _b = R.request("/api/settings?action=status", headers={"Origin": same}, timeout=12)
    ok("UAT-SEC-CORS-2", ":80 Settings API sends no CORS header",
       code == 200 and hdr(h, "Access-Control-Allow-Origin") == "",
       f"{code} {hdr(h, 'Access-Control-Allow-Origin')!r}")


def phase_settings() -> None:
    running = R.settings("status")
    if not running.get("ok"):
        running = R.settings_status()
    ok("UAT-SET-1", "settings status (auth not required)", bool(running.get("ok")))

    loc = R.settings("locale", {"confirm": "LANGUAGE", "lang": "en"})
    ok("UAT-SET-2", "language save en", bool(loc.get("ok")), loc.get("message") or loc.get("error") or "")

    conf = {}
    try:
        _c, conf = R.get_json("/api/settings?action=conf")
    except ConnectionError:
        conf = {}
    ok("UAT-SET-3", "read bitcoin.conf", bool(conf.get("ok") or "dbcache" in str(conf)), str(conf)[:160])
    dbcache = "450"
    if isinstance(conf, dict):
        text = str(conf.get("raw") or conf.get("conf") or "")
        for line in text.splitlines():
            if line.startswith("dbcache="):
                dbcache = line.split("=", 1)[1].strip()
                break
    saved = R.settings("conf_save", {"confirm": "SAVE", "dbcache": dbcache})
    ok(
        "UAT-SET-4",
        "conf_save same dbcache (node restarts)",
        bool(saved.get("ok")),
        fail_detail(saved),
    )
    if saved.get("ok"):
        wait_node_running(True, timeout=180)

    # B22/B23/U14 — change an allowlisted knob (TECH_SPEC: maxconnections 8–125).
    cur_mc = "40"
    raw = str(conf.get("raw") or "") if isinstance(conf, dict) else ""
    for line in raw.splitlines():
        if line.startswith("maxconnections="):
            cur_mc = line.split("=", 1)[1].strip()
            break
    try:
        cur_n = int(cur_mc)
    except ValueError:
        cur_n = 40
    new_mc = "50" if cur_n != 50 else "40"
    changed = R.settings("conf_save", {"confirm": "SAVE", "maxconnections": new_mc})
    ok(
        "UAT-SET-CONF",
        f"bitcoin.conf maxconnections {cur_mc} → {new_mc}",
        bool(changed.get("ok")),
        fail_detail(changed),
    )
    if changed.get("ok"):
        wait_node_running(True, timeout=180)
        try:
            _c, again = R.get_json("/api/settings?action=conf")
        except ConnectionError:
            again = {}
        raw2 = str(again.get("raw") or "")
        ok(
            "UAT-SET-CONF2",
            "maxconnections persisted after node restart",
            f"maxconnections={new_mc}" in raw2,
            raw2[:160],
        )
        R.settings("conf_save", {"confirm": "SAVE", "maxconnections": cur_mc})
        wait_node_running(True, timeout=180)

    start_busy = R.settings("node_start", {"confirm": "START"})
    if start_busy.get("error") == "already_running":
        ok("UAT-SET-5", "Start refused while running", True)
    elif start_busy.get("ok"):
        ok("UAT-SET-5", "Start refused while running", False, "node was stopped; start succeeded")
    else:
        ok(
            "UAT-SET-5",
            "Start refused while running",
            start_busy.get("error") in ("already_running", "reindex_in_progress"),
            fail_detail(start_busy),
        )

    stopped = R.settings("node_stop", {"confirm": "STOP"})
    stop_ok = bool(stopped.get("ok")) and wait_node_running(False, timeout=180)
    ok("UAT-SET-6", "Stop node", stop_ok, fail_detail(stopped))
    _verdict("UAT-SET-6R", "node_stop")
    started = R.settings("node_start", {"confirm": "START"})
    start_ok = bool(started.get("ok")) and wait_node_running(True, timeout=180)
    ok("UAT-SET-7", "Start node", start_ok, fail_detail(started))
    _verdict("UAT-SET-7R", "node_start")

    if env("KNOTS_UAT_REINDEX", "") == "1":
        R.settings("node_stop", {"confirm": "STOP"})
        rx = R.settings(
            "node_start",
            {"confirm": "START", "reindex": "1", "reindex_kind": "chainstate"},
        )
        ok("UAT-SET-8", "ReIndex chainstate started", bool(rx.get("ok")), rx.get("message") or "")
    else:
        st = R.settings_status()
        ok(
            "UAT-SET-8",
            "ReIndex contract present (not started)",
            "reindex_running" in st or html_has("/settings.html", "startReindex"),
        )


def phase_node() -> None:
    try:
        _c, data = R.get_json("/api/node?action=status")
    except ConnectionError:
        data = {}
    ok("UAT-ND-1", "Node software status", bool(data.get("ok")), str(data)[:160])
    if not data.get("ok"):
        return
    active = data.get("active")
    knots_ok = bool((data.get("knots") or {}).get("installed"))
    core_ok = bool((data.get("core") or {}).get("installed"))
    log(f"  .. active={active} knots={knots_ok} core={core_ok}")
    other = "knots" if active == "core" else "core"
    other_ok = knots_ok if other == "knots" else core_ok
    if not other_ok:
        ok("UAT-ND-2", f"switch skipped ({other} not installed)", True)
        return
    extra = {"impl": other, "confirm": "SWITCH"}
    if data.get("wallet_present") in (True, "true", 1, "1"):
        extra["wallet_ack"] = "WALLET_ACK"
    sw = R.node("set", extra)

    def _active_is(want: str) -> bool:
        try:
            _c, st = R.get_json("/api/node?action=status", https=True)
        except ConnectionError:
            try:
                _c, st = R.get_json("/api/node?action=status", https=False)
            except ConnectionError:
                return False
        if str(st.get("active") or "") != want:
            return False
        # L1: "active" flips before the switch worker has started the new
        # node; wait for the node-op lock to clear (.79: ND-3 node_busy).
        return not R.settings_status().get("node_busy", False)

    switched = bool(sw.get("ok")) and wait_until(
        f"active={other} + idle", lambda: _active_is(other), timeout=300, interval=3
    )
    ok("UAT-ND-2", f"switch to {other}", switched, fail_detail(sw))
    back = {"impl": str(active), "confirm": "SWITCH"}
    if extra.get("wallet_ack"):
        back["wallet_ack"] = "WALLET_ACK"
    sw2 = R.node("set", back)
    switched_back = bool(sw2.get("ok")) and wait_until(
        f"active={active} + idle", lambda: _active_is(str(active)), timeout=300, interval=3
    )
    ok("UAT-ND-3", f"switch back to {active}", switched_back, fail_detail(sw2))


def phase_luci() -> None:
    try:
        code, text = R.get_text("/", port=8080, timeout=12)
        ok(
            "UAT-L-1",
            "LuCI :8080 answers",
            code in (200, 302) and ("LuCI" in text or "Node" in text or "luci" in text.lower()),
            f"HTTP {code}",
        )
    except ConnectionError as exc:
        ok("UAT-L-1", "LuCI :8080 answers", False, str(exc))
    body = urllib.parse.urlencode(
        {"luci_username": USER, "luci_password": R.password}
    ).encode()
    try:
        # U1a — :8080 is nginx 302 to :8443; POST there becomes GET. Login on HTTPS.
        R.request("/cgi-bin/luci/", https=True, port=8443, timeout=15)
        code, _h, raw = R.request(
            "/cgi-bin/luci/",
            method="POST",
            data=body,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            https=True,
            port=8443,
            timeout=20,
        )
        text = raw.decode("utf-8", "replace")
        admin = R.request(
            "/cgi-bin/luci/admin/status/overview",
            https=True,
            port=8443,
            timeout=15,
        )
        admin_ok = admin[0] in (200, 302) and admin[0] != 403
        ok(
            "UAT-L-2",
            "LuCI login accepted",
            code in (200, 302) and "invalid" not in text.lower() and admin_ok,
            f"HTTP {code} admin={admin[0]}",
        )
    except ConnectionError as exc:
        ok("UAT-L-2", "LuCI login accepted", False, str(exc))


def phase_ui(prefix: str = "UAT-UI", shot_tag: str = "ui") -> None:
    """Node Status + Settings + Node software in the browser, then LuCI and back (U1/U1a/U2/U9)."""
    su = R.setup_status()
    if su.get("complete") is not True:
        ok(f"{prefix}-0", "Setup incomplete — skip Node UI browser walk", True)
        return

    def run(wiz: Any) -> None:
        wiz.open_node_status()
        ok(
            f"{prefix}-1",
            "Node Status shows sync/blocks",
            wiz.visible(".hero-status") and (wiz.visible("#blocks") or wiz.visible("#syncPct")),
        )
        wiz.click_nav("Node software")
        wiz.page.wait_for_timeout(800)
        ok(
            f"{prefix}-2",
            "Node software page from nav",
            "node.html" in (wiz.page.url or "") or wiz.visible("h1, h2"),
        )
        wiz.shot("node-software")
        wiz.click_nav("Settings")
        wiz.page.wait_for_timeout(800)
        ok(
            f"{prefix}-3",
            "Settings page from nav",
            "settings.html" in (wiz.page.url or "") or wiz.visible("#btnFactoryReset"),
        )
        wiz.shot("settings")
        wiz.open_node_status()
        wiz.open_luci_and_return(R.password)
        ok(
            f"{prefix}-4",
            "LuCI login then Node Dashboard return (U1a)",
            wiz.visible(".hero-status"),
        )

    try:
        with_wizard(HOST, _iue_shots(shot_tag), run)
    except Exception as exc:
        ok(f"{prefix}-4", "LuCI login then Node Dashboard return (U1a)", False, str(exc)[:240])


def phase_reboot() -> None:
    out = R.settings("reboot", {"confirm": "REBOOT"})
    ok("UAT-R-1", "Settings reboot accepted", bool(out.get("ok")), out.get("message") or out.get("error") or "")
    # The UI stays up while pre-reboot-stop stops bitcoind (≤90 s) and the LXC
    # — minutes on a synced node. "Back" only counts after the router has
    # actually gone down; otherwise the next phase races the pending reboot
    # (L1 now refuses it: .79 UAT UK-1 / F-1 node_busy "Stopping node and
    # rebooting").
    went_down = wait_until("reboot: router went down", lambda: not reachable(), timeout=900, interval=3)
    ready = went_down and wait_until("reboot return", reachable, timeout=420, interval=5)
    idle = ready and wait_until(
        "reboot: node idle",
        lambda: not R.settings_status().get("node_busy", False) and bool(R.settings_status().get("ok")),
        timeout=300,
        interval=5,
    )
    ok("UAT-R-2", "UI back after reboot (went down, came back, node idle)", bool(went_down and ready and idle),
       f"went_down={went_down} back={ready} idle={idle}")


def _upload_upgrade(keep: bool) -> dict[str, Any]:
    image, sha = find_image()
    log(f"  .. upload {image.name} keep_config={int(keep)} sha256={sha}")
    q = {
        "action": "upgrade",
        "confirm": "UPGRADE",
        "keep_config": "1" if keep else "0",
        "filename": image.name,
        "sha256": sha,
    }
    # S5 — raw-body upload: credentials in the Authorization header, never the URL.
    auth = "KnotsForm " + urllib.parse.urlencode({"user": USER, "password": R.password})
    data = image.read_bytes()
    code, _h, raw = R.request(
        "/api/settings",
        method="POST",
        data=data,
        headers={"Content-Type": "application/octet-stream", "Authorization": auth},
        query=q,
        timeout=900,
    )
    text = raw.decode("utf-8", "replace")
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        parsed = {"ok": False, "error": "not_json", "raw": text[:240], "http": code}
    return parsed


def _ca_pem() -> str:
    try:
        _c, pem = R.get_text("/knots-ca.crt", timeout=12)
    except ConnectionError:
        return ""
    return pem if "BEGIN CERTIFICATE" in pem else ""


def _ca_fp(pem: str) -> str:
    import base64
    import hashlib

    b64 = "".join(l for l in pem.splitlines() if l and "CERTIFICATE" not in l)
    try:
        return hashlib.sha256(base64.b64decode(b64)).hexdigest()
    except Exception:
        return ""


def _ca_constrained(pem: str) -> bool | None:
    """True/False from the laptop's openssl; None if openssl is unavailable."""
    import shutil
    import subprocess

    if not shutil.which("openssl"):
        return None
    r = subprocess.run(["openssl", "x509", "-noout", "-text"], input=pem,
                       capture_output=True, text=True, timeout=20)
    t = r.stdout
    return ("Name Constraints: critical" in t and "DNS:node-router" in t
            and "IP:192.168.0.0/255.255.0.0" in t)


def phase_upgrade_keep() -> None:
    ca_before = _ca_fp(_ca_pem())
    # U3: the owner's LAN / DHCP / timezone (Setup) survive a keep upgrade —
    # OpenWrt re-runs uci-defaults; 90-knots-network used to reset them.
    flash_before = str(R.settings_status().get("flash_id") or "")
    su_before = R.setup_status()
    net_before = (su_before.get("lan") or {}, su_before.get("zonename") or "")
    before = R.settings_status()
    prev = before.get("product_version") or (R.api_status().get("product_version") or "")
    out = _upload_upgrade(keep=True)
    ok("UAT-UK-1", "upgrade keep accepted", bool(out.get("ok")), out.get("message") or out.get("error") or "")
    time.sleep(5)
    try:
        _c, html = R.get_text("/", timeout=10)
        ok(
            "UAT-UK-2",
            "upgrade wait page or reboot",
            "Firmware" in html or "Upgrade" in html or not reachable(),
        )
    except ConnectionError:
        ok("UAT-UK-2", "router rebooting after upgrade", True)

    def _back() -> bool:
        if not reachable():
            return False
        st = R.settings_status() or R.api_status()
        ver = str(st.get("product_version") or "")
        return bool(ver) and not st.get("upgrade_live")

    ready = wait_until("upgrade keep return", _back, timeout=900, interval=8)
    ok("UAT-UK-3", "UI back after keep-settings upgrade", ready)
    after = R.settings_status() or R.api_status()
    ver = str(after.get("product_version") or "")
    image, _sha = find_image()
    expect = ""
    for part in image.name.split("-"):
        if part.count(".") >= 3:
            expect = part
            break
    if expect:
        ok("UAT-UK-4", f"product_version is {expect}", expect in ver, ver or prev)
    else:
        ok("UAT-UK-4", "product_version present after keep upgrade", bool(ver), ver)
    su = R.setup_status()
    ok("UAT-UK-5", "Setup still complete (keep settings)", su.get("complete") is True, str(su.get("complete")))
    # D3: a keep-settings upgrade must never rotate the CA (clients would
    # silently lose HTTPS trust).
    ca_after = _ca_fp(_ca_pem())
    ok("UAT-UK-6", "HTTPS CA unchanged by keep-settings upgrade (D3)",
       bool(ca_before) and ca_after == ca_before, f"{ca_before[:16]} → {ca_after[:16]}")
    flash_after = str(after.get("flash_id") or "")
    ok("UAT-UK-8", "image actually flashed (flash_id changed)",
       bool(flash_after) and flash_after != flash_before, f"{flash_before[:8]} → {flash_after[:8]}")
    net_after = (su.get("lan") or {}, su.get("zonename") or "")
    ok("UAT-UK-7", "LAN / DHCP / timezone kept by keep-settings upgrade (U3)",
       bool(net_before[0]) and net_after == net_before, f"{net_before} → {net_after}")


def phase_release_sig() -> None:
    """Signed releases (.97+): keys installed; an image whose pasted SHA256
    matches but that carries no valid release signature is refused without
    flashing. Skipped (not failed) on a build with no release key."""
    st = R.settings_status()
    if not st.get("release_sig_required"):
        ver = str(st.get("product_version") or "")
        bn = int(ver.rsplit(".", 1)[-1]) if ver.rsplit(".", 1)[-1].isdigit() else 0
        ok("UAT-SIG-1", "release keys installed (signing enforced)", bn < 97,
           f"{ver}: no release key" + ("" if bn < 97 else " — expected from .97"))
        return
    ok("UAT-SIG-1", "release keys installed (signing enforced)", True, f"channel={st.get('build_channel')}")
    image, _sha = find_image()
    # appended bytes: fwtool's trailer no longer parses → no valid signature;
    # the SHA256 is of these exact bytes, so only the signature gate can stop it
    data = image.read_bytes() + os.urandom(64)
    import hashlib
    sha = hashlib.sha256(data).hexdigest()
    flash_before = str(st.get("flash_id") or "")
    q = {"action": "upgrade", "confirm": "UPGRADE", "keep_config": "1",
         "filename": "unsigned-" + image.name, "sha256": sha}
    auth = "KnotsForm " + urllib.parse.urlencode({"user": USER, "password": R.password})
    code, _h, raw = R.request("/api/settings", method="POST", data=data,
                              headers={"Content-Type": "application/octet-stream", "Authorization": auth},
                              query=q, timeout=900)
    try:
        out = json.loads(raw.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        out = {"ok": False, "error": "not_json", "http": code}
    ok("UAT-SIG-2", "image without a valid release signature refused",
       out.get("ok") is False and out.get("error") in ("unsigned_image", "bad_signature"),
       f"{out.get('error')}: {out.get('message', '')[:80]}")
    time.sleep(20)
    after = R.settings_status()
    ok("UAT-SIG-3", "router still up and not flashed after the refusal",
       bool(after.get("ok")) and str(after.get("flash_id") or "") == flash_before
       and (after.get("upgrade") or {}).get("phase") not in ("applying", "verifying"),
       f"flash_id {flash_before[:8]} → {str(after.get('flash_id') or '')[:8]}")


def phase_factory() -> None:
    ca_before = _ca_fp(_ca_pem())
    out = R.settings("factory_reset", {"confirm": "RESET"})
    ok("UAT-F-1", "factory reset accepted", bool(out.get("ok")), out.get("message") or out.get("error") or "")
    time.sleep(3)
    try:
        _c, html = R.get_text("/", timeout=10)
        title = R.page_title(html)
        ok(
            "UAT-F-2",
            "reset wait page (not Firmware Update)",
            "Factory Reset" in html or "reset.html" in html.lower() or "Firmware Update" not in title,
            title or html[:80],
        )
    except ConnectionError:
        ok("UAT-F-2", "router dropped LAN during reset (expected)", True)

    def _iue() -> bool:
        if not reachable():
            return False
        su = R.setup_status()
        if su.get("factory_reset_live"):
            return False
        _c, html = R.get_text("/setup.html", timeout=10)
        return su.get("complete") is False and "Welcome to RNode" in html

    ready = wait_until("factory reset → IUE", _iue, timeout=1200, interval=8)
    if not ready:
        ok("UAT-F-3", "IUE Welcome after factory reset", False, "setup.html never showed Welcome")
    else:
        try:
            def _welcome(wiz: Any) -> None:
                wiz.open_setup()
                if not wiz.visible("#btnWelcome"):
                    raise RuntimeError("Continue not visible on Welcome")

            with_wizard(HOST, _iue_shots("factory-welcome"), _welcome)
            ok("UAT-F-3", "IUE Welcome Continue visible after factory reset", True)
        except Exception as exc:
            ok("UAT-F-3", "IUE Welcome Continue visible after factory reset", False, str(exc)[:240])
    R.password = FACTORY_PASS
    if ready:
        _check_factory_wifi()
        # P3/D3: factory reset issues a NEW, name-constrained CA.
        pem = _ca_pem()
        new_fp = _ca_fp(pem)
        cons = _ca_constrained(pem)
        ok("UAT-F-CA", "factory reset: new CA" + ("" if cons is None else ", name-constrained (P3)"),
           bool(new_fp) and new_fp != ca_before and cons is not False,
           f"{ca_before[:16]} → {new_fp[:16]} constrained={cons}")


def _check_factory_wifi() -> None:
    """P1: after a factory reset a labelled unit enables Wi-Fi rnode (label
    secret); an unlabelled unit keeps every radio OFF until Setup. Read from
    Setup status wifi_on (router UCI) — the UAT laptop may not rescan Wi-Fi
    (NetworkManager polkit), so an SSID scan would be stale."""
    want = EXPECT_LABELLED

    def _state() -> bool:
        su = R.setup_status()
        return "wifi_on" in su and su.get("wifi_on") is want

    good = wait_until("factory Wi-Fi state", _state, timeout=180 if want else 30, interval=10)
    su = R.setup_status()
    ok(
        "UAT-F-WIFI",
        "factory Wi-Fi " + ("ON — rnode with label secret (labelled unit)" if want else "OFF until Setup (unlabelled unit)"),
        good,
        f"wifi_on={su.get('wifi_on')} factory_labelled={su.get('factory_labelled')}",
    )


def _dns_a(name: str, server: str) -> str:
    """One A query straight to the router's DNS (not the laptop's resolver)."""
    import random, socket, struct
    qid = random.randint(0, 65535)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0) + b"".join(
        bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00" + struct.pack(">HH", 1, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(4)
    try:
        s.sendto(q, (server, 53)); r = s.recv(1500)
    except OSError as exc:
        return f"error {exc}"
    finally:
        s.close()
    an = struct.unpack(">H", r[6:8])[0]
    i = len(q)
    for _ in range(an):
        i += 2 if r[i] & 0xC0 == 0xC0 else r.index(b"\x00", i) + 1 - i
        typ, _cls, _ttl, ln = struct.unpack(">HHIH", r[i:i + 10]); i += 10
        if typ == 1 and ln == 4:
            return ".".join(str(b) for b in r[i:i + 4])
        i += ln
    return "no A record"


def _captive(tag: str, expect_on: bool) -> None:
    """First-use captive portal (captive-portal.sh): before Setup the router's
    DNS points connectivity checks at itself and :80 redirects them to Setup."""
    a = _dns_a("connectivitycheck.gstatic.com", HOST)
    try:
        code, hdrs, _b = R.request("/generate_204", headers={"Host": "connectivitycheck.gstatic.com"}, timeout=10)
    except ConnectionError as exc:
        code, hdrs = 0, {"error": str(exc)}
    loc = hdrs.get("Location") or hdrs.get("location") or ""
    if expect_on:
        # public test address (Android ignores portals on private IPs) + router redirect
        ok(f"UAT-CAP-{tag}", "before Setup: connectivity check → 192.0.2.1 (DNS) → Setup redirect",
           a == "192.0.2.1" and code == 302 and "setup.html" in loc, f"dns={a} http={code} {loc}")
    else:
        ok(f"UAT-CAP-{tag}", "after Setup: connectivity check no longer captured",
           a not in (HOST, "192.0.2.1") and code != 302, f"dns={a} http={code}")


def phase_iue_quick() -> None:
    su = R.setup_status()
    if su.get("complete") is True:
        ok("UAT-IQ-0", "Setup already complete — skip Quick Start", True)
        return
    _captive("1", expect_on=True)

    def run(wiz: Any) -> None:
        wiz.open_setup()
        ok(
            "UAT-IQ-1",
            "Welcome visible with Continue",
            wiz.visible("#btnWelcome") and wiz.visible("#stepWelcome"),
        )
        wiz.welcome_continue()
        ok(
            "UAT-IQ-SEC",
            "Security page (Linux Terminal one-liner)",
            wiz.visible("#stepTls") and wiz.visible("#tlsLinuxOneLiner"),
        )
        try:
            wiz.security_then_after_tls()
            ok(
                "UAT-IQ-F208",
                "after CA install IUE continues at Choice not Welcome",
                wiz.visible("#stepChoice") and not wiz.visible("#stepWelcome"),
            )
        except Exception as exc:
            ok(
                "UAT-IQ-F208",
                "after CA install IUE continues at Choice not Welcome",
                False,
                str(exc)[:240],
            )
            wiz.security_linux_then_skip()
        ok(
            "UAT-IQ-2",
            "Choice: Quick Start and Guided Setup buttons",
            wiz.visible("#btnQuick") and wiz.visible("#btnGuided"),
        )
        wiz.enter_quick()
        try:
            wiz.reject_factory_router_password()
            ok("UAT-IUE-N1", "Quick Start UI rejects factory router password", True)
        except Exception as exc:
            ok("UAT-IUE-N1", "Quick Start UI rejects factory router password", False, str(exc)[:240])
        wiz.quick_finish(QUICK_PASS, UAT_WIFI)

    try:
        with_wizard(HOST, _iue_shots("quick"), run)
        R.password = QUICK_PASS
        ok("UAT-IQ-3", "Quick Start Finish clicked in the wizard", True)
    except Exception as exc:
        ok("UAT-IQ-3", "Quick Start Finish clicked in the wizard", False, str(exc)[:240])
        return

    def _done() -> bool:
        if not reachable():
            return False
        return R.setup_status().get("complete") is True

    ready = wait_until("Quick Start settle", _done, timeout=240, interval=5)
    ok("UAT-IQ-4", "Setup complete after Quick Start", ready)
    st = R.api_status()
    ok("UAT-IQ-5", "Node Status after Quick Start", bool(st.get("product_version")), str(st)[:160])


def phase_upgrade_reset() -> None:
    flash_before = str(R.settings_status().get("flash_id") or "")
    out = _upload_upgrade(keep=False)
    ok("UAT-UR-1", "upgrade reset-settings accepted", bool(out.get("ok")), out.get("message") or out.get("error") or "")
    time.sleep(5)

    def _iue() -> bool:
        if not reachable():
            return False
        su = R.setup_status()
        if su.get("upgrade_live"):
            return False
        _c, html = R.get_text("/setup.html", timeout=10)
        return su.get("complete") is False and "Welcome to RNode" in html

    ready = wait_until("upgrade -n → IUE", _iue, timeout=1200, interval=8)
    if not ready:
        ok("UAT-UR-2", "IUE Welcome after reset-settings upgrade", False, "setup.html never showed Welcome")
    else:
        try:
            def _welcome(wiz: Any) -> None:
                wiz.open_setup()
                if not wiz.visible("#btnWelcome"):
                    raise RuntimeError("Continue not visible on Welcome")

            with_wizard(HOST, _iue_shots("upgrade-reset-welcome"), _welcome)
            ok("UAT-UR-2", "IUE Welcome Continue after reset-settings upgrade", True)
        except Exception as exc:
            ok("UAT-UR-2", "IUE Welcome Continue after reset-settings upgrade", False, str(exc)[:240])
    flash_after = str(R.settings_status().get("flash_id") or "")
    ok("UAT-UR-3", "image actually flashed (flash_id changed)",
       bool(flash_after) and flash_after != flash_before, f"{flash_before[:8]} → {flash_after[:8]}")
    R.password = FACTORY_PASS


def phase_iue_guided() -> None:
    su = R.setup_status()
    if su.get("complete") is True:
        ok("UAT-IG-0", "Setup already complete — skip Guided", True)
        return

    def run(wiz: Any) -> None:
        wiz.open_setup()
        ok("UAT-IG-1", "Welcome Continue", wiz.visible("#btnWelcome"))
        wiz.welcome_continue()
        ok("UAT-IG-SEC", "Security page before after_tls resume", wiz.visible("#stepTls"))
        try:
            wiz.security_then_after_tls()
            ok(
                "UAT-IG-F208",
                "HTTPS after_tls / rnode.local resume at Choice",
                wiz.visible("#stepChoice") and not wiz.visible("#stepWelcome"),
            )
        except Exception as exc:
            ok(
                "UAT-IG-F208",
                "HTTPS after_tls / rnode.local resume at Choice",
                False,
                str(exc)[:240],
            )
            wiz.security_linux_then_skip()
        ok("UAT-IG-2", "Guided Setup button", wiz.visible("#btnGuided"))
        staged = wiz.guided_finish(
            GUIDED_PASS, UAT_WIFI, ssid=GUIDED_SSID, dhcp_start=GUIDED_DHCP_START
        )
        lan = staged.get("lan") if isinstance(staged.get("lan"), dict) else {}
        ok(
            "UAT-IG-LAN",
            f"Guided custom LAN DHCP start {GUIDED_DHCP_START}",
            str(lan.get("dhcp_start") or "") == GUIDED_DHCP_START,
            str(lan)[:160],
        )
        ok(
            "UAT-IG-SSID",
            f"Guided custom SSID {GUIDED_SSID}",
            getattr(wiz, "applied_ssid", "") == GUIDED_SSID,
            getattr(wiz, "applied_ssid", "") or "wifi form hidden",
        )

    try:
        with_wizard(HOST, _iue_shots("guided"), run)
        R.password = GUIDED_PASS
        ok("UAT-IG-3", "Guided Node/WAN/LAN/Wi-Fi/password/Done clicked", True)
    except Exception as exc:
        ok("UAT-IG-3", "Guided Node/WAN/LAN/Wi-Fi/password/Done clicked", False, str(exc)[:240])
        return

    def _done() -> bool:
        if not reachable():
            return False
        return R.setup_status().get("complete") is True

    ready = wait_until("Guided settle", _done, timeout=240, interval=5)
    ok("UAT-IG-8", "Setup complete after Guided", ready)
    if ready:
        time.sleep(5)
        _captive("2", expect_on=False)
    st = R.api_status()
    ok("UAT-IG-9", "Node Status after Guided", bool(st.get("product_version")), str(st)[:160])
    phase_ui(prefix="UAT-IG-UI", shot_tag="guided-ui")


HANDLERS = {
    "pages": phase_pages,
    "status": phase_status,
    "nav": phase_nav,
    "security": phase_security,
    "settings": phase_settings,
    "node": phase_node,
    "luci": phase_luci,
    "ui": phase_ui,
    "reboot": phase_reboot,
    "upgrade_keep": phase_upgrade_keep,
    "release_sig": phase_release_sig,
    "factory": phase_factory,
    "iue_quick": phase_iue_quick,
    "upgrade_reset": phase_upgrade_reset,
    "iue_guided": phase_iue_guided,
}


# ---------------------------------------------------------------------------
# Opt-in hardware phases (2026-10-18, pre-production): not in PHASES — run with
# ONLY=node_bins / ONLY=lan_move. They cover paths the default run cannot:
# node binary install / rollback (official tarballs) and a LAN IP change in
# Setup with the old-IP hold window.
TARBALL_DIR = Path(env("KNOTS_UAT_TARBALLS", str(Path.home() / "Documents" / "knots-uat" / "tarballs")))
CORE_TGZ = "bitcoin-29.4-aarch64-linux-gnu.tar.gz"
KNOTS_TGZ = "bitcoin-29.3.knots20260507-aarch64-linux-gnu.tar.gz"
MOVE_IP = env("KNOTS_UAT_MOVE_IP", "192.168.77.1")


def _node_status() -> dict[str, Any]:
    for https in (True, False):
        try:
            _c, st = R.get_json("/api/node?action=status", https=https)
            if st.get("ok"):
                return st
        except ConnectionError:
            continue
    return {}


def _node_verdict(cid: str, op: str, what: str, timeout: float = 900) -> bool:
    """L2/L3: wait for the detached worker's own verdict in node status."""
    def _done() -> bool:
        lo = _node_status().get("last_op") or {}
        return lo.get("op") == op and lo.get("state") in ("ok", "failed")
    wait_until(f"{op} verdict", _done, timeout=timeout, interval=5)
    lo = _node_status().get("last_op") or {}
    good = lo.get("op") == op and lo.get("state") == "ok"
    ok(cid, what, good, f"{lo.get('state')}: {lo.get('message')}")
    return good


def _upload_tarball(impl: str, path: Path) -> dict[str, Any]:
    import hashlib
    data = path.read_bytes()
    sha = hashlib.sha256(data).hexdigest()
    auth = "KnotsForm " + urllib.parse.urlencode({"user": USER, "password": R.password})
    code, _h, raw = R.request(
        "/api/node", method="POST", data=data, https=True, timeout=900,
        headers={"Content-Type": "application/gzip", "Authorization": auth},
        query={"action": "install", "impl": impl, "confirm": "INSTALL", "name": path.name,
               "sha256": sha, "wallet_ack": "WALLET_ACK"},
    )
    try:
        return json.loads(raw.decode("utf-8", "replace"))
    except json.JSONDecodeError:
        return {"ok": False, "error": "not_json", "http": code, "raw": raw[:200].decode("utf-8", "replace")}


def phase_node_bins() -> None:
    core_t, knots_t = TARBALL_DIR / CORE_TGZ, TARBALL_DIR / KNOTS_TGZ
    if not core_t.is_file() or not knots_t.is_file():
        ok("UAT-NB-0", f"tarballs present in {TARBALL_DIR}", False, f"need {CORE_TGZ} + {KNOTS_TGZ}")
        return
    st = _node_status()
    active = str(st.get("active") or "core")
    log(f"  .. node-bins start: active={active} core={st.get('core')} knots={st.get('knots')}")

    # 1. Install the ACTIVE implementation (restart path) — CGI answers at once (L3).
    out = _upload_tarball(active, core_t if active == "core" else knots_t)
    ok("UAT-NB-1", f"install {active} accepted (detached, no proxy timeout)", bool(out.get("ok")) and bool(out.get("accepted")), fail_detail(out))
    if out.get("ok"):
        _node_verdict("UAT-NB-2", "install", f"install {active} worker verdict ok")
        st = _node_status()
        ok("UAT-NB-3", f"{active}.prev kept for rollback", bool((st.get(active) or {}).get("prev_available")), str(st.get(active)))
        ok("UAT-NB-4", "node running again after install restart", wait_node_running(True, timeout=600), "")

    # 2. Roll back the active implementation.
    rb = R.node("rollback", {"impl": active, "confirm": "ROLLBACK", "wallet_ack": "WALLET_ACK"})
    ok("UAT-NB-5", f"rollback {active} accepted", bool(rb.get("ok")) and bool(rb.get("accepted")), fail_detail(rb))
    if rb.get("ok"):
        _node_verdict("UAT-NB-6", "rollback", f"rollback {active} worker verdict ok")
        ok("UAT-NB-7", "node running after rollback", wait_node_running(True, timeout=600), "")

    # 3. Install the INACTIVE implementation (no restart); version label from the file name.
    other = "knots" if active == "core" else "core"
    tgz = knots_t if other == "knots" else core_t
    out = _upload_tarball(other, tgz)
    ok("UAT-NB-8", f"install {other} accepted", bool(out.get("ok")) and bool(out.get("accepted")), fail_detail(out))
    if out.get("ok"):
        _node_verdict("UAT-NB-9", "install", f"install {other} worker verdict ok")
        st = _node_status()
        ver = str((st.get(other) or {}).get("version") or "")
        want = "29.3.knots20260507" if other == "knots" else "29.4"
        ok("UAT-NB-10", f"{other} version recorded ({want})", want in ver and not ver.startswith("3."), ver)
        ok("UAT-NB-11", f"active impl unchanged ({active})", str(st.get("active")) == active, str(st.get("active")))


LAPTOP_MOVE_ADDR = env("KNOTS_UAT_LAPTOP_MOVE_ADDR", "192.168.77.50/24")
LAPTOP_IFACE = env("KNOTS_UAT_LAPTOP_IFACE", "enp2s0")


def _laptop_addr(op: str) -> bool:
    """Add/del a laptop address on the moved subnet (narrow NOPASSWD sudo rule
    for `ip addr add|del <addr> dev <iface>`). Without it the router would be
    stranded on MOVE_IP once the old-IP hold window ends."""
    import subprocess
    r = subprocess.run(["sudo", "-n", "/usr/sbin/ip", "addr", op, LAPTOP_MOVE_ADDR, "dev", LAPTOP_IFACE],
                       capture_output=True, text=True, timeout=20)
    return r.returncode == 0 or (op == "add" and "File exists" in r.stderr)


def phase_lan_move() -> None:
    """Guided Setup onto MOVE_IP, verify the cutover, then return to HOST."""
    if not _laptop_addr("add"):
        ok("UAT-LM-0", f"laptop can reach {MOVE_IP} (sudo ip addr add {LAPTOP_MOVE_ADDR})", False,
           "no NOPASSWD rule — skipped; moving the LAN would strand the router")
        return
    try:
        _phase_lan_move()
    finally:
        _laptop_addr("del")


def _phase_lan_move() -> None:
    def _to_iue(tag: str) -> bool:
        out = R.settings("factory_reset", {"confirm": "RESET"})
        ok(f"UAT-LM-{tag}R", f"factory reset accepted ({R.host})", bool(out.get("ok")), fail_detail(out))
        time.sleep(5)
        # a factory reset always comes back on the factory address, whatever
        # LAN IP Setup had moved it to (lan_move .97: polled the moved IP)
        R.host = HOST

        def _iue() -> bool:
            if not reachable():
                return False
            su = R.setup_status()
            return su.get("complete") is False and not su.get("factory_reset_live")
        return wait_until("factory reset → IUE", _iue, timeout=1200, interval=8)

    if not _to_iue("1"):
        ok("UAT-LM-1", "IUE after factory reset", False, "never reached Setup")
        return
    R.password = FACTORY_PASS
    staged: dict[str, Any] = {}
    try:
        def _guided(wiz: Any) -> None:
            nonlocal staged
            wiz.open_setup()
            wiz.welcome_continue()
            wiz.security_linux_then_skip()
            staged = wiz.guided_finish(GUIDED_PASS, UAT_WIFI, lan_ip=MOVE_IP)
            wiz.shot("after-lan-move")
            url = wiz.page.url or ""
            ok("UAT-LM-2", f"browser followed to {MOVE_IP} (D2 IP host)", MOVE_IP in url, url)

        with_wizard(HOST, _iue_shots("lan-move"), _guided)
        ok("UAT-LM-1", f"Guided Setup with LAN {MOVE_IP} finished", True)
    except Exception as exc:
        ok("UAT-LM-1", f"Guided Setup with LAN {MOVE_IP} finished", False, str(exc)[:240])
    R.password = GUIDED_PASS
    old_host = R.host
    R.host = MOVE_IP
    moved = wait_until(f"router answers on {MOVE_IP}", reachable, timeout=240, interval=5)
    su = R.setup_status()
    ok("UAT-LM-3", f"router serves on {MOVE_IP}; LAN ip reported",
       moved and str((su.get("lan") or {}).get("ipaddr")) == MOVE_IP, str(su.get("lan")))
    # HTTPS leaf covers the new IP (SAN), verified against the router's CA.
    try:
        import socket, ssl as _ssl
        pem = _ca_pem()
        ctx = _ssl.create_default_context(cadata=pem)
        with socket.create_connection((MOVE_IP, 443), timeout=10) as raw:
            with ctx.wrap_socket(raw, server_hostname=MOVE_IP):
                pass
        ok("UAT-LM-4", f"HTTPS certificate valid for {MOVE_IP}", True)
    except Exception as exc:
        ok("UAT-LM-4", f"HTTPS certificate valid for {MOVE_IP}", False, str(exc)[:200])
    # Old IP: answered during the ~120 s hold (alias), then removed (C3).
    R.host = old_host
    gone = wait_until(f"old IP {old_host} released after hold", lambda: not reachable(), timeout=420, interval=10)
    ok("UAT-LM-5", f"old IP {old_host} released after the hold window", gone, "")
    R.host = MOVE_IP
    log(f"  .. staged at Done: lan={staged.get('lan')}")
    # Return to the standard address: factory reset on the moved IP → HOST.
    back = _to_iue("2")
    ok("UAT-LM-6", f"factory reset from {MOVE_IP} returned the router to {HOST} (Setup)", back, "")
    R.password = FACTORY_PASS
    if back:
        phase_iue_guided()


# opt-in (ONLY=…), not in the default PHASES
HANDLERS["node_bins"] = phase_node_bins
HANDLERS["lan_move"] = phase_lan_move


def selected_phases() -> list[str]:
    only = env("ONLY", "")
    start = env("START_AT", PHASES[0])
    if only:
        wanted = [p.strip() for p in only.split(",") if p.strip()]
        unknown = [p for p in wanted if p not in HANDLERS]
        if unknown:
            raise SystemExit(f"unknown ONLY phases: {unknown} (want {PHASES})")
        return wanted
    if start not in PHASES:
        raise SystemExit(f"unknown START_AT={start} (want {PHASES})")
    return PHASES[PHASES.index(start) :]


def maybe_bootstrap_iue() -> None:
    """If the box is still on IUE, finish Quick Start so Settings tests can auth."""
    su = R.setup_status()
    if not su:
        return
    if su.get("complete") is True:
        return
    if su.get("factory_reset_live") or su.get("upgrade_live"):
        return
    log("== bootstrap IUE (Setup incomplete at start) ==")
    phase_iue_quick()


def main() -> int:
    _open_run_log()
    extra: dict[str, Any] = {}
    exit_code = 0
    try:
        log(f"Knots web UAT  host={HOST}  user={USER}  run_id={_RUN_ID}")
        log("No serial. No SD/eMMC flash. No M.2 wipe.")
        try:
            image, sha = find_image()
            extra["image"] = str(image)
            extra["sha256"] = sha
            log(f"Upgrade image: {image} ({image.stat().st_size} bytes)")
            log(f"SHA256: {sha}")
        except (FileNotFoundError, ValueError) as exc:
            log(f"FAIL image: {exc}")
            exit_code = 2
            return exit_code
        if not reachable():
            log(f"FAIL: cannot reach http://{HOST}/ — plug LAN and retry")
            exit_code = 2
            return exit_code
        discover_password()
        phases = selected_phases()
        extra["phases"] = phases
        log(f"Phases: {', '.join(phases)}")
        if phases[0] in (
            "pages",
            "status",
            "nav",
            "settings",
            "node",
            "luci",
            "ui",
            "reboot",
            "upgrade_keep",
        ):
            maybe_bootstrap_iue()
        for name in phases:
            log(f"== {name} ==")
            HANDLERS[name]()
        log("")
        passed = sum(1 for r in RESULTS if r["pass"])
        log(f"{passed} passed, {len(FAILS)} failed, {len(RESULTS)} checks")
        if FAILS:
            log("FAILED:")
            for item in FAILS:
                log(f"  {item}")
            log(f"Current router password in this session: {R.password}")
            exit_code = 1
            return exit_code
        log(f"ALL PASS. Router password now: {R.password}")
        log("Wi-Fi PSK if Setup applied Wi-Fi: " + UAT_WIFI)
        exit_code = 0
        return exit_code
    except Exception:
        log(traceback.format_exc())
        exit_code = 3
        return exit_code
    finally:
        st: dict[str, Any] = {}
        try:
            st = R.api_status() or R.settings_status()
        except Exception:
            pass
        extra["product_version"] = st.get("product_version")
        write_summary(exit_code, extra)
        if _LOG_FH is not None:
            _LOG_FH.close()


if __name__ == "__main__":
    raise SystemExit(main())
