# SPDX-License-Identifier: GPL-2.0-only
"""Minimal Firefox Marionette client (no extra packages) for the user-guide
screenshots: start a headless Firefox, open pages, run a script, save a PNG."""
import base64, json, os, socket, subprocess, time


class Firefox:
    def __init__(self, profile, width=1280, height=900, port=2828, prefs=None):
        os.makedirs(profile, exist_ok=True)
        p = {"marionette.port": port, "browser.shell.checkDefaultBrowser": False,
             "datareporting.policy.dataSubmissionEnabled": False, "toolkit.telemetry.enabled": False,
             "browser.aboutwelcome.enabled": False, "app.update.disabledForTesting": True,
             "network.dns.localDomains": "rnode.local,rnode-4216.local,node-router",
             "security.enterprise_roots.enabled": False, "ui.systemUsesDarkTheme": 0}
        p.update(prefs or {})
        with open(os.path.join(profile, "user.js"), "w") as f:
            for k, v in p.items():
                f.write(f"user_pref({json.dumps(k)}, {json.dumps(v)});\n")
        self.proc = subprocess.Popen(["firefox", "--headless", "--marionette", "--no-remote", "--profile", profile,
                                      f"--width={width}", f"--height={height}"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        end = time.time() + 60
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", port), timeout=5)
                break
            except OSError:
                if time.time() > end:
                    raise
                time.sleep(0.5)
        self.sock.settimeout(120)
        self.buf, self.mid = b"", 0
        self._recv()                                   # handshake
        self.cmd("WebDriver:NewSession", {"acceptInsecureCerts": True})   # the stand-in's self-signed HTTPS
        self.cmd("WebDriver:SetWindowRect", {"width": width, "height": height})

    def _recv(self):
        while b":" not in self.buf:
            self.buf += self.sock.recv(65536)
        n, rest = self.buf.split(b":", 1)
        n = int(n)
        while len(rest) < n:
            rest += self.sock.recv(65536)
        msg, self.buf = rest[:n], rest[n:]
        return json.loads(msg)

    def cmd(self, name, params=None):
        self.mid += 1
        data = json.dumps([0, self.mid, name, params or {}]).encode()
        self.sock.sendall(str(len(data)).encode() + b":" + data)
        while True:
            r = self._recv()
            if r[0] == 1 and r[1] == self.mid:
                if r[2]:
                    raise RuntimeError(f"{name}: {r[2]}")
                return r[3]

    def go(self, url):
        self.cmd("WebDriver:Navigate", {"url": url})

    def js(self, script, args=None):
        return self.cmd("WebDriver:ExecuteScript", {"script": script, "args": args or []}).get("value")

    def size(self, width, height):
        self.cmd("WebDriver:SetWindowRect", {"width": width, "height": height})

    def shot(self, path, full=True, css=None):
        p = {"full": full}
        if css:                                        # one element (a panel), not the page
            el = self.cmd("WebDriver:FindElement", {"using": "css selector", "value": css})["value"]
            p = {"id": next(iter(el.values())), "full": False}
        v = self.cmd("WebDriver:TakeScreenshot", p)["value"]
        with open(path, "wb") as f:
            f.write(base64.b64decode(v))

    def quit(self):
        try:
            self.cmd("Marionette:Quit", {"flags": ["eForceQuit"]})
        except Exception:
            pass
        try:
            self.proc.wait(10)
        except Exception:
            self.proc.kill()
