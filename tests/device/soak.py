#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Soak test for a release candidate (pre-production review, 2026-10-18).

Runs on the UAT laptop against the test router for SOAK_HOURS (default 48):
  * every HEALTH_MIN (10) minutes — health: Settings + Setup APIs answer,
    :80 / :443 / LuCI :8443 up, node running and not stuck busy, block height
    not going backwards and advancing over each hour, no last_op failures
  * every REBOOT_HOURS (2) — Settings reboot; must go down and come back
    healthy within RECOVER_MIN (15)
  * every UPGRADE_HOURS (8) — keep-settings upgrade with the same image;
    must really flash (flash_id changes) and come back healthy

Writes results/soak-<run>.jsonl (one event per line) and a summary at the
end; exits 1 on any failure. Uses the UAT's Router client (uat-web.py), so it
authenticates with the UAT's own known test password only.

env: SOAK_HOURS HEALTH_MIN REBOOT_HOURS UPGRADE_HOURS RECOVER_MIN KNOTS_UAT_HOST
"""
import importlib.util
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("uat", HERE / "uat-web.py")
uat = importlib.util.module_from_spec(spec)
sys.argv = [sys.argv[0]]
spec.loader.exec_module(uat)

HOURS = float(os.environ.get("SOAK_HOURS", "48"))
HEALTH_MIN = float(os.environ.get("HEALTH_MIN", "10"))
REBOOT_H = float(os.environ.get("REBOOT_HOURS", "2"))
UPGRADE_H = float(os.environ.get("UPGRADE_HOURS", "8"))
RECOVER_MIN = float(os.environ.get("RECOVER_MIN", "15"))
RUN = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
SOAK_T0 = int(time.time())
OUT = HERE / "results" / f"soak-{RUN}.jsonl"
R = uat.R
failures: list[dict] = []
stats = {"health": 0, "health_fail": 0, "reboots": 0, "upgrades": 0, "max_recover_s": 0}
heights: list[tuple[float, int]] = []


def emit(kind: str, ok: bool, **kw) -> None:
    ev = {"t": datetime.now(timezone.utc).isoformat(), "kind": kind, "ok": ok, **kw}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("a") as f:
        f.write(json.dumps(ev) + "\n")
    print(json.dumps(ev), flush=True)
    if not ok:
        failures.append(ev)


def node_height() -> int:
    for https in (True, False):
        try:
            _c, d = R.get_json("/api/status", https=https)
            k = d.get("knots") or {}
            # not running = still starting (RPC warm-up): height unknown, not 0
            if k.get("running") and k.get("blocks") is not None:
                return int(k["blocks"])
        except Exception:
            continue
    return -1


def port_up(port: int, https: bool) -> bool:
    try:
        code, _h, _b = R.request("/", https=https, port=port, timeout=10)
        return code in (200, 302, 303, 307)
    except Exception:
        return False


def health(tag: str) -> bool:
    st = R.settings_status()
    su = R.setup_status()
    h = node_height()
    checks = {
        "settings_api": bool(st.get("ok")),
        "setup_api": bool(su.get("ok")),
        "http80": port_up(80, False),
        "https443": port_up(443, True),
        "luci8443": port_up(8443, True),
        "node_running": bool(st.get("node_running")),
        "not_stuck_busy": not st.get("node_busy"),
        # only node operations that ran during this soak count
        "no_failed_op": not ((st.get("last_op") or {}).get("state") == "failed"
                             and int((st.get("last_op") or {}).get("ts") or 0) >= SOAK_T0),
        "height_known": h >= 0,
    }
    if heights and h >= 0 and h < heights[-1][1]:
        checks["height_monotonic"] = False
    if h >= 0:
        heights.append((time.time(), h))
    good = all(checks.values())
    stats["health"] += 1
    if not good:
        stats["health_fail"] += 1
    emit("health", good, tag=tag, height=h, version=st.get("product_version"),
         failed=[k for k, v in checks.items() if not v])
    return good


def wait_healthy(label: str, t0: float) -> bool:
    deadline = t0 + RECOVER_MIN * 60
    while time.time() < deadline:
        time.sleep(15)
        if uat.reachable() and R.settings_status().get("ok") and R.settings_status().get("node_running") \
                and not R.settings_status().get("node_busy") and node_height() >= 0:
            took = int(time.time() - t0)
            stats["max_recover_s"] = max(stats["max_recover_s"], took)
            emit(label + "_recovered", True, seconds=took)
            return health(label)
    emit(label + "_recovered", False, seconds=int(time.time() - t0))
    return False


def do_reboot() -> None:
    stats["reboots"] += 1
    t0 = time.time()
    out = R.settings("reboot", {"confirm": "REBOOT"})
    if not out.get("ok"):
        emit("reboot_request", False, detail=str(out)[:200])
        return
    went = uat.wait_until("soak reboot down", lambda: not uat.reachable(), timeout=900, interval=3)
    emit("reboot_down", went)
    wait_healthy("reboot", t0)


def do_upgrade() -> None:
    stats["upgrades"] += 1
    before = str(R.settings_status().get("flash_id") or "")
    t0 = time.time()
    out = uat._upload_upgrade(keep=True)
    if not out.get("ok"):
        emit("upgrade_request", False, detail=str(out)[:200])
        return
    uat.wait_until("soak upgrade down", lambda: not uat.reachable(), timeout=900, interval=5)
    if wait_healthy("upgrade", t0):
        after = str(R.settings_status().get("flash_id") or "")
        emit("upgrade_flashed", bool(after) and after != before, before=before[:8], after=after[:8])


def main() -> int:
    uat.discover_password()
    end = time.time() + HOURS * 3600
    next_reboot = time.time() + REBOOT_H * 3600
    next_upgrade = time.time() + UPGRADE_H * 3600
    emit("start", True, hours=HOURS, host=uat.HOST, image=str(uat.find_image()[0].name))
    # The soak often starts right after a UAT run whose last phase restarted
    # the node: wait for it to be ready, like after every reboot (.102 soak).
    wait_healthy("start", time.time())
    last_hour_check = time.time()
    while time.time() < end:
        time.sleep(HEALTH_MIN * 60)
        health("periodic")
        now = time.time()
        if now - last_hour_check >= 3600 and len(heights) >= 2:
            recent = [h for t, h in heights if t >= now - 3600]
            emit("height_advancing", len(recent) >= 2 and recent[-1] > recent[0],
                 first=recent[0] if recent else None, last=recent[-1] if recent else None)
            last_hour_check = now
        if now >= next_upgrade:
            do_upgrade()
            next_upgrade = now + UPGRADE_H * 3600
            next_reboot = max(next_reboot, time.time() + 1800)
        elif now >= next_reboot:
            do_reboot()
            next_reboot = now + REBOOT_H * 3600
    summary = {**stats, "failures": len(failures),
               "height_start": heights[0][1] if heights else None,
               "height_end": heights[-1][1] if heights else None}
    emit("summary", not failures, **summary)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
