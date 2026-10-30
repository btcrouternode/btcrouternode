#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Drive IUE the way a person does: click Welcome, Security, Quick/Guided.

API POSTs to /api/setup skip setup.js (steps, Skip, Finish wait, rnode.local).
This module uses Playwright Chromium on the laptop. Required for iue_quick /
iue_guided. Not serial. Not an M.2 wipe.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Callable

# P1: on a labelled router the factory password is its label secret (refused
# server-side as a "new" password); unlabelled routers: legacy knotsnode21.
FACTORY_PASS = os.environ.get("KNOTS_UAT_FACTORY_PASS", "knotsnode21")
# T-IUE-CLIENT Guided SSID; LAN DHCP start is factory 100 (FIRST_RUN_UX / U17).
GUIDED_SSID = "ClientGuided"
GUIDED_DHCP_START = "110"


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def ensure_playwright() -> Any:
    try:
        from playwright.sync_api import sync_playwright
    except ImportError as exc:
        raise RuntimeError(
            "IUE UAT needs Playwright (a real browser). On the laptop: "
            "python3 -m pip install --user --break-system-packages playwright "
            "&& python3 -m playwright install chromium"
        ) from exc
    return sync_playwright


class IueWizard:
    """One Chromium tab through Setup, same buttons as FIRST_RUN_UX."""

    def __init__(self, host: str, shots: Path) -> None:
        self.host = host
        self.shots = shots
        self._pw_cm: Any = None
        self._pw: Any = None
        self._browser: Any = None
        self.page: Any = None
        self._n = 0

    def start(self) -> None:
        sync_playwright = ensure_playwright()
        self._pw_cm = sync_playwright()
        self._pw = self._pw_cm.__enter__()
        headed = env("KNOTS_UAT_HEADED", "") == "1"
        self._browser = self._pw.chromium.launch(
            headless=not headed,
            args=[
                f"--host-resolver-rules=MAP rnode.local {self.host},"
                f"MAP knots-router {self.host},MAP node-router {self.host}"
            ],
        )
        ctx = self._browser.new_context(
            ignore_https_errors=True,
            locale="en-AU",
            timezone_id="Australia/Sydney",
            accept_downloads=True,
            user_agent=(
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            ),
        )
        self.page = ctx.new_page()
        self.page.set_default_timeout(45_000)

    def close(self) -> None:
        try:
            if self._browser is not None:
                self._browser.close()
        finally:
            self._browser = None
            if self._pw_cm is not None:
                self._pw_cm.__exit__(None, None, None)
                self._pw_cm = None

    def shot(self, name: str) -> None:
        self._n += 1
        self.shots.mkdir(parents=True, exist_ok=True)
        path = self.shots / f"{self._n:02d}-{name}.png"
        try:
            self.page.screenshot(path=str(path), full_page=True)
        except Exception:
            pass

    def banner(self) -> str:
        loc = self.page.locator("#banner")
        try:
            if loc.count() and loc.first.is_visible():
                return (loc.inner_text() or "").strip()
        except Exception:
            return ""
        return ""

    def visible(self, sel: str) -> bool:
        loc = self.page.locator(sel)
        try:
            return loc.count() > 0 and loc.first.is_visible()
        except Exception:
            return False

    def wait_vis(self, sel: str, timeout: float = 30_000) -> None:
        self.page.locator(sel).first.wait_for(state="visible", timeout=timeout)

    def click(self, sel: str, timeout: float = 30_000) -> None:
        self.wait_vis(sel, timeout=timeout)
        self.page.locator(sel).first.click()

    def fill(self, sel: str, value: str) -> None:
        self.wait_vis(sel)
        self.page.locator(sel).first.fill(value)

    def open_setup(self) -> None:
        self.page.goto(
            f"http://{self.host}/setup.html",
            wait_until="domcontentloaded",
            timeout=30_000,
        )
        self.wait_vis("#stepWelcome")
        self.shot("welcome")

    def welcome_continue(self) -> None:
        if not self.visible("#btnWelcome"):
            raise RuntimeError("Welcome Continue not visible (setup.js did not show step 0)")
        self.click("#btnWelcome")
        self.wait_vis("#stepTls")
        self.shot("security")

    def security_linux_then_skip(self) -> None:
        if not self.visible("#stepTls"):
            raise RuntimeError("Security page did not open after Continue")
        self.page.wait_for_function(
            """() => {
              var el = document.getElementById('tlsLinuxOneLiner');
              return !!(el && el.textContent && el.textContent.indexOf('wget') !== -1);
            }""",
            timeout=15_000,
        )
        one = ""
        if self.visible("#tlsLinuxOneLiner"):
            one = self.page.locator("#tlsLinuxOneLiner").inner_text()
        if "wget" not in one and "install-linux.sh" not in one:
            raise RuntimeError(
                "Linux IUE Security is missing the Terminal one-liner a user would paste"
            )
        if self.visible("#tlsLinuxOneLinerWrap"):
            try:
                self.click("#tlsLinuxOneLinerWrap")
            except Exception:
                pass
        if not self.visible("#btnTlsSkip"):
            raise RuntimeError("Skip for now not visible on Security")
        self.click("#btnTlsSkip")
        self.wait_vis("#stepChoice", timeout=20_000)
        self.shot("choice")

    def resume_after_tls(self) -> None:
        """F208 — after the CA is installed the wizard continues at Choice, not Welcome."""
        self.page.goto(
            f"https://rnode.local/setup.html?after_tls=1",
            wait_until="domcontentloaded",
            timeout=30_000,
        )
        self.wait_vis("#stepChoice", timeout=20_000)
        if self.visible("#stepWelcome"):
            raise RuntimeError("after_tls=1 opened Welcome instead of Choice (F208)")
        if not self.visible("#btnQuick") or not self.visible("#btnGuided"):
            raise RuntimeError("Choice buttons missing after after_tls=1")
        self.shot("after-tls-choice")

    def https_root_resumes_choice(self) -> None:
        self.page.goto(
            "https://rnode.local/",
            wait_until="domcontentloaded",
            timeout=30_000,
        )
        self.wait_vis("#stepChoice", timeout=20_000)
        if self.visible("#stepWelcome"):
            raise RuntimeError("https://rnode.local/ mid-IUE restarted Welcome (F208)")
        self.shot("https-root-choice")

    def security_then_after_tls(self) -> None:
        if not self.visible("#stepTls"):
            raise RuntimeError("Security page did not open after Continue")
        self.page.wait_for_function(
            """() => {
              var el = document.getElementById('tlsLinuxOneLiner');
              return !!(el && el.textContent && el.textContent.indexOf('wget') !== -1);
            }""",
            timeout=15_000,
        )
        self.resume_after_tls()
        self.https_root_resumes_choice()

    def reject_factory_router_password(self) -> str:
        self.fill("#quickPw1", FACTORY_PASS)
        self.fill("#quickPw2", FACTORY_PASS)
        if self.visible("#quickWifiKey"):
            self.fill("#quickWifiKey", "uattestwifi99")
            self.fill("#quickWifiKey2", "uattestwifi99")
        self.click("#btnQuickSubmit")
        self.page.wait_for_timeout(2000)
        msg = self.banner().lower()
        self.shot("factory-password-rejected")
        if "factory" not in msg and FACTORY_PASS not in msg and "knotsnode" not in msg:
            raise RuntimeError(f"Quick Start accepted factory password; banner={self.banner()!r}")
        return self.banner()

    def _dismiss_pppoe_if_any(self) -> None:
        modal = self.page.locator("#quickPppoeModal")
        try:
            if modal.count() and modal.first.is_visible():
                self.click("#btnQuickPppoeSkip")
        except Exception:
            pass

    def enter_quick(self) -> None:
        self.wait_vis("#btnQuick")
        self.click("#btnQuick")
        self.wait_vis("#stepQuick")
        self.shot("quick")

    def quick_finish(self, router_pass: str, wifi_psk: str) -> None:
        self.fill("#quickPw1", router_pass)
        self.fill("#quickPw2", router_pass)
        if self.visible("#quickWifiKey"):
            self.fill("#quickWifiKey", wifi_psk)
            self.fill("#quickWifiKey2", wifi_psk)
        self.click("#btnQuickSubmit")
        self.page.wait_for_timeout(1500)
        self._dismiss_pppoe_if_any()
        self._wait_after_finish()

    def guided_finish(
        self,
        router_pass: str,
        wifi_psk: str,
        ssid: str = GUIDED_SSID,
        dhcp_start: str = GUIDED_DHCP_START,
        lan_ip: str = "",
    ) -> dict[str, Any]:
        self.wait_vis("#btnGuided")
        self.click("#btnGuided")
        self.wait_vis("#stepNode")
        self.shot("guided-node")
        core = self.page.locator('input[name="impl"][value="core"]')
        if core.count():
            core.first.check()
        self.click("#btnNode")
        self.wait_vis("#stepWan", timeout=20_000)
        self.shot("guided-wan")
        try:
            self.wait_vis("#btnWanContinue", timeout=90_000)
            self.click("#btnWanContinue")
        except Exception:
            if self.visible("#btnWanSkip"):
                self.click("#btnWanSkip")
            else:
                raise RuntimeError("WAN Continue/Skip never appeared")
        self.wait_vis("#stepLan", timeout=20_000)
        self.shot("guided-lan")
        details = self.page.locator("#lanDetails")
        if details.count():
            details.first.evaluate("el => { el.open = true; }")
        if lan_ip:
            self.fill("#lanIp", lan_ip)
        self.fill("#lanDhcpStart", dhcp_start)
        self.click("#btnLan")
        self.wait_vis("#stepWifi", timeout=60_000)
        self.shot("guided-wifi")
        self.applied_ssid = ""
        if self.visible("#wifiSsid"):
            self.fill("#wifiSsid", ssid)
            self.applied_ssid = ssid
            self.fill("#wifiKey", wifi_psk)
            self.fill("#wifiKey2", wifi_psk)
            if self.visible("#wifiCountry"):
                cc = self.page.locator("#wifiCountry").input_value() or ""
                if len(cc.strip()) != 2:
                    self.fill("#wifiCountry", "AU")
            self.click("#btnWifi")
        self.wait_vis("#stepPassword", timeout=60_000)
        self.shot("guided-password")
        self.fill("#pw1", FACTORY_PASS)
        self.fill("#pw2", FACTORY_PASS)
        self.click("#btnPassword")
        self.page.wait_for_timeout(2000)
        msg = self.banner().lower()
        if "factory" not in msg and "knotsnode" not in msg and FACTORY_PASS not in msg:
            if self.visible("#stepPassword"):
                raise RuntimeError(f"Guided accepted factory password; banner={self.banner()!r}")
        self.fill("#pw1", router_pass)
        self.fill("#pw2", router_pass)
        self.click("#btnPassword")
        self.wait_vis("#stepDone", timeout=30_000)
        self.shot("guided-done")
        staged = {}
        try:
            staged = self.page.evaluate(
                """async () => {
                  const r = await fetch('/api/setup?action=status', { cache: 'no-store' });
                  return await r.json();
                }"""
            )
        except Exception:
            staged = {}
        self.click("#btnDone")
        self._wait_after_finish()
        return staged if isinstance(staged, dict) else {}

    def _wait_after_finish(self) -> None:
        self.shot("after-finish")
        # Finish may show the restart wait, Done, or jump to Node Status.
        for _ in range(80):
            url = self.page.url or ""
            if self.visible("#stepRestart") or self.visible("#waitProgress"):
                self.page.wait_for_timeout(2000)
                continue
            if "index.html" in url or url.rstrip("/").endswith(self.host):
                if "setup.html" not in url:
                    return
            if self.visible(".hero-status") or self.visible("#syncRing") or (
                self.page.locator("text=Node Status").count() > 0
                and "setup.html" not in url
            ):
                return
            if self.visible("#stepDone") and self.visible("#btnDone"):
                try:
                    self.click("#btnDone")
                except Exception:
                    pass
            self.page.wait_for_timeout(2000)
        raise RuntimeError(
            f"After Finish the browser is still not on Node Status (url={self.page.url})"
        )

    def open_node_status(self) -> None:
        self.page.goto(
            f"https://{self.host}/",
            wait_until="domcontentloaded",
            timeout=30_000,
        )
        self.wait_vis(".hero-status", timeout=30_000)
        self.shot("node-status")

    def click_nav(self, label: str) -> None:
        self.page.locator("nav#topnav a", has_text=label).first.click()

    def open_luci_and_return(self, password: str) -> None:
        self.click_nav("Router settings")
        self.page.wait_for_url("**/cgi-bin/luci/**", timeout=20_000)
        user = self.page.locator('input[name="luci_username"]')
        if user.count() and user.first.is_visible():
            user.first.fill("root")
            self.page.locator('input[name="luci_password"]').first.fill(password)
            btn = self.page.locator('input[type="submit"], button[type="submit"]')
            if btn.count():
                btn.first.click()
            else:
                self.page.locator('input[name="luci_password"]').first.press("Enter")
        self.page.wait_for_timeout(2000)
        self.shot("luci")
        ret = self.page.locator("#knots-return-bar a, #knots-login-return a")
        if not ret.count():
            raise RuntimeError("LuCI is missing the Node Dashboard return link (U1a)")
        ret.first.click()
        self.wait_vis(".hero-status", timeout=30_000)
        self.shot("node-status-from-luci")


def with_wizard(host: str, shots: Path, fn: Callable[[IueWizard], None]) -> None:
    wiz = IueWizard(host, shots)
    try:
        wiz.start()
        fn(wiz)
    except Exception:
        try:
            wiz.shot("fail")
        except Exception:
            pass
        raise
    finally:
        wiz.close()
