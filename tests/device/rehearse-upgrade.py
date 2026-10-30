#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Rehearse the off-site tester's upgrade in a real browser (2026-10-12).

Starting point: router on an OLD build (.73/.74) with Setup done. Exactly the
tester's clicks: Settings → Appliance upgrade → choose the .itb, paste the
SHA256, switch "Keep settings" → "Reset settings", router password, UPGRADE,
Verify & upgrade → wait page → (router reboots into the new build) → Setup
Welcome → Security → Quick Start → Node Status.

Every stage is screenshotted and every visible status line is logged with
its elapsed time, so the tester guide describes what really happens.

env: KNOTS_UAT_HOST (192.168.1.254) IMAGE=…itb SHA=… OLD_PASS=… NEW_PASS=…
     NEW_WIFI=… SHOTS=dir
"""
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from uat_wizard import IueWizard  # noqa: E402

HOST = os.environ.get("KNOTS_UAT_HOST", "192.168.1.254")
IMAGE = os.environ["IMAGE"]
SHA = os.environ["SHA"]
OLD_PASS = os.environ["OLD_PASS"]
NEW_PASS = os.environ.get("NEW_PASS", "uattest99")
NEW_WIFI = os.environ.get("NEW_WIFI", "uattestwifi99")
SHOTS = Path(os.environ.get("SHOTS", "results/rehearsal"))
T0 = time.time()


def log(msg: str) -> None:
    print(f"[{int(time.time() - T0):4d}s] {msg}", flush=True)


def text_of(page, sel: str) -> str:
    try:
        loc = page.locator(sel)
        if loc.count() and loc.first.is_visible():
            return " ".join(loc.first.inner_text().split())[:200]
    except Exception:
        pass
    return ""


def main() -> int:
    wiz = IueWizard(HOST, SHOTS)
    wiz.start()
    page = wiz.page
    page.on("dialog", lambda d: (log(f"browser dialog: {' '.join(d.message.split())[:200]}"), d.accept()))
    try:
        # 1. Settings page on the old build
        page.goto(f"https://{HOST}/settings.html", wait_until="domcontentloaded", timeout=45_000)
        page.wait_for_selector("#btnUpgrade", timeout=45_000)
        page.wait_for_timeout(2500)
        log(f"Settings opened: {page.url}")
        wiz.shot("settings-old-build")
        page.locator("#btnUpgrade").scroll_into_view_if_needed()
        wiz.shot("upgrade-panel-empty")

        # 2. Fill the upgrade form like the tester
        page.set_input_files("#upgradeFile", IMAGE)
        page.fill("#upgradeSha256", SHA)
        page.click("#upgradeKeepToggle")
        page.wait_for_timeout(500)
        log(f"keep toggle aria-checked={page.get_attribute('#upgradeKeepToggle', 'aria-checked')} "
            f"hint={text_of(page, '#upgradeKeepHint')!r}")
        page.fill("#upgradeUser", "root")
        page.fill("#upgradePass", OLD_PASS)
        page.fill("#upgradeConfirm", "UPGRADE")
        wiz.shot("upgrade-panel-filled")
        page.click("#btnUpgrade")
        log("clicked Verify & upgrade")

        # 3. Wait page → reboot → new build's Setup Welcome
        last = ""
        deadline = time.time() + 30 * 60
        n = 0
        while time.time() < deadline:
            page.wait_for_timeout(5000)
            n += 1
            url = page.url
            status = " | ".join(x for x in (
                text_of(page, "#waitTitle"), text_of(page, "#waitProgressLabel"),
                text_of(page, "#waitHint"), text_of(page, "#banner"),
                text_of(page, "h1")) if x)
            line = f"{url}  ::  {status}"
            if line != last:
                log(line)
                last = line
            if n % 12 == 0:
                wiz.shot("waiting")
            if "setup.html" in url and wiz.visible("#stepWelcome"):
                log("Setup Welcome reached on the new build")
                break
        else:
            wiz.shot("wait-timeout")
            log("TIMEOUT: Setup Welcome did not appear within 30 min — what a tester would see is in the last screenshot")
            log(f"Manual fallback: open http://{HOST}/ ")
            page.goto(f"http://{HOST}/", wait_until="domcontentloaded", timeout=45_000)
            page.wait_for_timeout(4000)
            log(f"after manual open: {page.url}")
            if not wiz.visible("#stepWelcome"):
                wiz.shot("manual-open")
                return 1

        wiz.shot("new-build-welcome")
        log(f"Welcome text: {text_of(page, '#stepWelcome')!r}")

        # 4. Setup on .94 — Security page (screenshot; the tester runs the
        #    installer, automation skips), Quick Start, Node Status
        wiz.welcome_continue()
        log(f"Security page: {text_of(page, '#stepTls')[:160]!r}")
        wiz.security_linux_then_skip()
        wiz.enter_quick()
        wiz.quick_finish(NEW_PASS, NEW_WIFI)
        log(f"after Finish: {page.url}")
        wiz.open_node_status()
        log(f"Node Status: {page.url}")
        wiz.shot("node-status")
        log("REHEARSAL OK")
        return 0
    except Exception as exc:
        log(f"REHEARSAL FAILED: {exc}")
        wiz.shot("fail")
        return 1
    finally:
        wiz.close()


if __name__ == "__main__":
    sys.exit(main())
