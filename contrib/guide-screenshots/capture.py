#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Regenerate the screenshots in docs/user-guide/img/ for docs/USER_GUIDE.md.

The router's real web pages (files/www/knots) are opened in a headless Firefox
against a stand-in router (mock_router.py) that answers in a chosen state.
Run after any UI change:

    python3 contrib/guide-screenshots/capture.py            # all shots
    python3 contrib/guide-screenshots/capture.py status-    # names starting with …

Needs Firefox (snap is fine) and openssl. Test values only — never real passwords.
"""
import json, os, shutil, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
OUT = os.path.join(ROOT, "docs", "user-guide", "img")
# A snap Firefox can only use folders under ~/snap/firefox/common.
WORK = os.path.expanduser(os.environ.get("GUIDE_SHOTS_WORK", "~/snap/firefox/common/rnode-shots"))
sys.path.insert(0, HERE)
from marionette import Firefox  # noqa: E402

HTTP = "http://rnode.local:18080"
HTTPS = "https://rnode.local:18443"

UA = {
    "linux": ("Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:132.0) Gecko/20100101 Firefox/132.0", "Linux x86_64"),
    "windows": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:132.0) Gecko/20100101 Firefox/132.0", "Win32"),
    "mac": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 14.5; rv:132.0) Gecko/20100101 Firefox/132.0", "MacIntel"),
    "phone": ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) "
              "Version/17.5 Mobile/15E148 Safari/604.1", "iPhone"),
}

# helpers available to every shot's script
JS_LIB = r"""
window.__g = {
  click: function (id) { var e = document.getElementById(id); if (!e) throw new Error('no #' + id); e.click(); },
  fill: function (id, v) { var e = document.getElementById(id); if (!e) throw new Error('no #' + id);
    e.value = v; e.dispatchEvent(new Event('input', {bubbles: true})); e.dispatchEvent(new Event('change', {bubbles: true})); },
  open: function (id) { var e = document.getElementById(id); if (e) e.open = true; },
  tag: function () { document.querySelectorAll('section.panel').forEach(function (s) {
    var h = s.querySelector('h2'); if (h) s.setAttribute('data-shot', h.textContent.trim().toLowerCase()
      .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')); }); }
};
"""

DONE = {"setup": {"complete": True, "password_done": True, "locale_done": True}}
PW_A, PW_B = "Example-router-pass1", "Example-wifi-pass22"   # dummy test values for the screenshots


def S(name, url, ua="linux", scenario=None, steps=(), css=None, size=(1280, 900), full=True, dark=False):
    return dict(name=name, url=url, ua=ua, scenario=scenario or {}, steps=list(steps), css=css, size=size,
                full=full, dark=dark)


# steps: ("js", "code") | ("wait", seconds)
def W(s): return ("wait", s)
def J(c): return ("js", c)


GUIDED_TO_WAN = [J("__g.click('btnGuided')"), W(1), J("__g.click('btnNode')"), W(4)]

SHOTS = [
    # --- Setup (first-run) ------------------------------------------------
    S("setup-01-welcome", HTTP + "/setup.html"),
    S("setup-02-security-windows", HTTP + "/setup.html", ua="windows", steps=[J("__g.click('btnWelcome')"), W(2)]),
    S("setup-02-security-mac", HTTP + "/setup.html", ua="mac", steps=[J("__g.click('btnWelcome')"), W(2)]),
    S("setup-02-security-linux", HTTP + "/setup.html", ua="linux", steps=[J("__g.click('btnWelcome')"), W(2)]),
    S("setup-02-security-help", HTTP + "/setup.html", ua="windows",
      steps=[J("__g.click('btnWelcome')"), W(2), J("__g.open('tlsHelp')"), W(1)]),
    S("setup-02-security-waiting", HTTP + "/setup.html", ua="windows",
      steps=[J("__g.click('btnWelcome')"), W(2),
             # keep the page: the download itself is not part of the picture
             J("document.getElementById('tlsPrimaryCta').addEventListener('click', function (e) { e.preventDefault(); });"
               "__g.click('tlsPrimaryCta')"), W(5)]),
    S("setup-03-choice", HTTPS + "/setup.html?after_tls=1", steps=[W(2)]),
    S("setup-03-choice-locale", HTTPS + "/setup.html?after_tls=1", steps=[W(2), J("__g.open('choiceLocaleEdit')"), W(1)]),
    S("setup-04-quick", HTTPS + "/setup.html?after_tls=1", steps=[W(2), J("__g.click('btnQuick')"), W(5)]),
    S("setup-04-quick-error", HTTPS + "/setup.html?after_tls=1",
      steps=[W(2), J("__g.click('btnQuick')"), W(4), J(f"__g.fill('quickPw1','{PW_A}');__g.fill('quickPw2','Example-router-pass2');"
                                                      f"__g.fill('quickWifiKey','{PW_B}');__g.fill('quickWifiKey2','{PW_B}');"
                                                      "__g.click('btnQuickSubmit')"), W(1)]),
    S("setup-04-quick-isp", HTTPS + "/setup.html?after_tls=1",
      scenario={"setup": {"wan": {"up": False, "proto": "dhcp", "ipv4": ""}}},
      steps=[W(2), J("__g.click('btnQuick')"), W(26)]),
    S("setup-04-quick-finish-wait", HTTPS + "/setup.html?after_tls=1",
      scenario={"setup": {"client_wifi": True}, "post": {"/api/setup?action=quickstart": {
          "ok": True, "wifi_reconnect": True, "lan_moved": False, "ssid": "rnode", "lan_ip": "192.168.1.254",
          "message": "Setup complete.", "redirect": "https://rnode.local/"}}},
      steps=[W(2), J("__g.click('btnQuick')"), W(4), J(f"__g.fill('quickPw1','{PW_A}');__g.fill('quickPw2','{PW_A}');"
                                                      f"__g.fill('quickWifiKey','{PW_B}');__g.fill('quickWifiKey2','{PW_B}');"
                                                      "__g.click('btnQuickSubmit')"), W(5)]),
    S("setup-05-node", HTTPS + "/setup.html?after_tls=1", steps=[W(2), J("__g.click('btnGuided')"), W(2)]),
    S("setup-06-internet-ok", HTTPS + "/setup.html?after_tls=1", steps=[W(2)] + GUIDED_TO_WAN),
    S("setup-06-internet-fail", HTTPS + "/setup.html?after_tls=1",
      scenario={"setup": {"wan": {"up": False, "proto": "dhcp", "ipv4": ""}}}, steps=[W(2)] + GUIDED_TO_WAN + [W(26)]),
    S("setup-06-internet-isp", HTTPS + "/setup.html?after_tls=1",
      scenario={"setup": {"wan": {"up": False, "proto": "dhcp", "ipv4": ""}}},
      steps=[W(2)] + GUIDED_TO_WAN + [W(26), J("__g.click('btnWanPppoe')"), W(1)]),
    S("setup-07-lan", HTTPS + "/setup.html?after_tls=1",
      steps=[W(2)] + GUIDED_TO_WAN + [J("__g.click('btnWanContinue')"), W(1), J("__g.open('lanDetails')"), W(1)]),
    S("setup-08-wifi", HTTPS + "/setup.html?after_tls=1",
      steps=[W(2)] + GUIDED_TO_WAN + [J("__g.click('btnWanContinue')"), W(1), J("__g.click('btnLanContinue')"), W(2)]),
    S("setup-09-password", HTTPS + "/setup.html?after_tls=1",
      steps=[W(2)] + GUIDED_TO_WAN + [J("__g.click('btnWanContinue')"), W(1), J("__g.click('btnLanContinue')"), W(2),
                                      J(f"__g.fill('wifiKey','{PW_B}');__g.fill('wifiKey2','{PW_B}');__g.click('btnWifi')"), W(5)]),
    S("setup-10-done", HTTPS + "/setup.html?after_tls=1",
      scenario={"setup": {"password_done": True, "locale_done": True}},
      steps=[W(2)] + GUIDED_TO_WAN + [J("__g.click('btnWanContinue')"), W(1), J("__g.click('btnLanContinue')"), W(2),
                                      J(f"__g.fill('wifiKey','{PW_B}');__g.fill('wifiKey2','{PW_B}');__g.click('btnWifi')"), W(5),
                                      J(f"__g.fill('pw1','{PW_A}');__g.fill('pw2','{PW_A}');__g.click('btnPassword')"), W(3)]),
    S("setup-phone", HTTP + "/setup.html", ua="phone", size=(390, 844)),

    # --- Node Status ------------------------------------------------------
    S("status-synced", HTTPS + "/", scenario=DONE, steps=[W(3)]),
    S("status-syncing", HTTPS + "/", scenario=dict(DONE, status={"knots": {
        "verification_progress": 0.4213, "blocks": 612480, "headers": 925410, "peers": 9, "uptime_sec": 86400 * 2 + 3600 * 5},
        "storage": {"free_bytes": 1650000000000}}), steps=[W(3)]),
    S("status-initialising", HTTPS + "/", scenario=dict(DONE, status={
        "maintenance": {"active": True, "op": "starting", "message": "Node is initialising — starting Bitcoin. Status will update when ready."},
        "knots": {"running": False, "verification_progress": 0, "blocks": 0, "headers": 0, "peers": 0, "uptime_sec": 0, "best_block_hash": "", "error": "starting"}}),
      steps=[W(3)]),
    S("status-waiting-time", HTTPS + "/", scenario=dict(DONE, status={
        "maintenance": {"active": True, "op": "waiting_clock", "message": "Waiting for the correct time. The router sets its clock from the internet; the node starts by itself as soon as it has (your blockchain is fine)."},
        "knots": {"running": False, "verification_progress": 0, "blocks": 0, "headers": 0, "peers": 0, "uptime_sec": 0, "best_block_hash": "", "error": None}}),
      steps=[W(3)]),
    S("status-needs-repair", HTTPS + "/", scenario=dict(DONE, status={
        "recovery": {"needs_reindex": True, "kind": "chainstate", "hint": "Node cannot start until the chain database is repaired. This rebuilds chainstate from blocks already on the M.2 — it does not download the blockchain again."},
        "knots": {"running": False, "verification_progress": 0, "blocks": 0, "headers": 0, "peers": 0, "uptime_sec": 0, "best_block_hash": "", "error": "node_failed_to_become_ready"}}),
      steps=[W(3)]),
    S("status-not-running", HTTPS + "/", scenario=dict(DONE, status={
        "knots": {"running": False, "verification_progress": 0, "blocks": 0, "headers": 0, "peers": 0, "uptime_sec": 0, "best_block_hash": "", "error": "storage_not_ready"},
        "storage": {"mounted": False, "free_bytes": 0}}), steps=[W(3)]),
    S("status-drive-attention", HTTPS + "/", scenario=dict(DONE, status={"disk": {
        "level": "attention", "reasons": ["wear_high"], "percent_used": 84}}), steps=[W(3)]),
    S("status-power-lost", HTTPS + "/", scenario=dict(DONE, status={"disk": {"power_loss_recent": True}}), steps=[W(3)]),
    S("status-low-space", HTTPS + "/", scenario=dict(DONE, status={"storage": {"free_bytes": 61000000000, "low_space": True}}),
      steps=[W(3)]),
    S("status-dark", HTTPS + "/", scenario=DONE, steps=[W(3)], dark=True),

    # --- Node software ----------------------------------------------------
    S("node-software", HTTPS + "/node.html", scenario=DONE, steps=[W(3)]),

    # --- Settings (one panel per picture, plus the whole page) -------------
    S("settings-page", HTTPS + "/settings.html", scenario=DONE, steps=[W(3)]),
] + [
    S("settings-" + key, HTTPS + "/settings.html", scenario=DONE, steps=[W(3), J("__g.tag()")],
      css=f'[data-shot="{slug}"]', size=(1280, 2600))
    for key, slug in [("language", "language"), ("node", "node-start-stop"), ("power", "appliance-power"),
                      ("reset", "factory-reset"), ("upgrade", "appliance-upgrade"),
                      ("conf-beginner", "bitcoin-node-configuration-beginner-user"),
                      ("conf-experienced", "bitcoin-node-configuration-experienced-user")]
] + [
    S("settings-start-reindex", HTTPS + "/settings.html",
      scenario=dict(DONE, settings={"node_running": False}, status={"knots": {"running": False}}),
      steps=[W(3), J("__g.tag(); var c=document.querySelector('[data-shot=\"node-start-stop\"] input[type=checkbox]');"
                     "if(c){c.checked=true;c.dispatchEvent(new Event('change',{bubbles:true}));}"), W(1)],
      css='[data-shot="node-start-stop"]', size=(1280, 2600)),

    # --- Upgrade / factory reset progress ----------------------------------
    S("upgrade-progress-keep", HTTP + "/upgrade.html?go=1", scenario=dict(DONE, settings={
        "upgrade_live": True, "upgrade_keep_config": True, "upgrade_expected_seconds": 300, "progress_step": "updating",
        "progress_label": "Updating Router"}, setup={"upgrade_live": True, "progress_step": "updating"}), steps=[W(9)]),
    S("upgrade-progress-reset", HTTP + "/upgrade.html?go=1&keep=0", scenario=dict(DONE, settings={
        "upgrade_live": True, "upgrade_keep_config": False, "upgrade_expected_seconds": 630, "progress_step": "stop_node",
        "progress_label": "Stopping BTC Node"}, setup={"upgrade_live": True, "upgrade_keep_config": False,
                                                      "progress_step": "stop_node"}), steps=[W(4)]),
    S("upgrade-failed", HTTP + "/upgrade.html?go=1", scenario=dict(DONE, settings={
        "upgrade_live": False, "upgrade": {"phase": "failed", "detail": "SHA256 re-verify mismatch — upload again from Settings"}}),
      steps=[W(5)]),
    S("reset-progress", HTTP + "/reset.html?hw=1", scenario=dict(DONE, settings={
        "factory_reset_active": True, "factory_reset_live": True, "progress_step": "reset_settings",
        "progress_label": "Resetting Router Settings"}, setup={"factory_reset_active": True, "factory_reset_live": True,
                                                              "progress_step": "reset_settings"}), steps=[W(4)]),

    # --- Secure connection (add a computer) -------------------------------
    S("tls-add-windows", HTTP + "/tls.html?add=1", ua="windows", scenario=DONE, steps=[W(4)]),
    S("tls-add-mac", HTTP + "/tls.html?add=1", ua="mac", scenario=DONE, steps=[W(4)]),
    S("tls-add-linux", HTTP + "/tls.html?add=1", ua="linux", scenario=DONE, steps=[W(4)]),
    S("tls-phone", HTTP + "/tls.html?add=1", ua="phone", scenario=DONE, size=(390, 844), steps=[W(3)]),

    # --- Router settings entry (LuCI) -------------------------------------
    S("luci-entry", HTTP + "/luci-entry.html", scenario=DONE, steps=[W(1)]),
]


def shrink(path):
    """256-colour PNG: about a quarter of the size, no visible loss on these flat UI pages."""
    try:
        from PIL import Image
    except ImportError:
        return
    im = Image.open(path).convert("RGB")
    im.quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.FLOYDSTEINBERG).save(path, optimize=True)


def scenario(sc):
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:18080/__scenario",
                                                  data=json.dumps(sc).encode(), method="POST"), timeout=5)


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else ""
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    mock = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_router.py"), "--workdir",
                             os.path.join(WORK, "mock")], stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    time.sleep(1.5)
    ff, cur, failed = None, None, []
    try:
        for s in SHOTS:
            if only and not s["name"].startswith(only):
                continue
            key = (s["ua"], s["size"])
            if key != cur:                                   # new Firefox per device type
                if ff:
                    ff.quit()
                prof = os.path.join(WORK, "prof-" + s["ua"])
                shutil.rmtree(prof, ignore_errors=True)
                ua, plat = UA[s["ua"]]
                ff = Firefox(prof, width=s["size"][0], height=s["size"][1], prefs={
                    "general.useragent.override": ua, "general.platform.override": plat,
                    "browser.download.folderList": 2, "browser.download.dir": os.path.join(WORK, "dl"),
                    "browser.download.useDownloadDir": True, "browser.download.always_ask_before_handling_new_types": False})
                cur = key
            try:
                scenario(s["scenario"])
                ff.go(s["url"].split("?")[0].rsplit("/", 1)[0] + "/favicon.ico")    # same origin, blank
                ff.js("try{localStorage.setItem('knots-ui-theme', arguments[0])}catch(e){}",
                      ["dark" if s["dark"] else "light"])
                ff.go(s["url"])
                ff.js(JS_LIB)
                for kind, v in s["steps"]:
                    if kind == "wait":
                        time.sleep(v)
                    else:
                        ff.js(JS_LIB + v)
                path = os.path.join(OUT, s["name"] + ".png")
                ff.shot(path, full=s["full"], css=s["css"])
                shrink(path)
                print("ok  ", s["name"], flush=True)
            except Exception as e:
                failed.append(s["name"])
                print("FAIL", s["name"], str(e)[:200], flush=True)
    finally:
        if ff:
            ff.quit()
        mock.terminate()
    if failed:
        print("failed:", " ".join(failed))
        sys.exit(1)


if __name__ == "__main__":
    main()
