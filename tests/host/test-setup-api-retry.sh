#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# T-SETUP-RETRY — setup.js api() retries an nginx 502 (backend uhttpd briefly
# restarting after a firmware boot; the CGI never ran) but not a uhttpd 502
# (the CGI ran and died). .79 UAT Guided Node step hit the former.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
command -v node >/dev/null 2>&1 || { echo "SKIP T-SETUP-RETRY: node not installed"; exit 0; }
JS="$ROOT/files/www/knots/setup.js" node <<'NODE'
const src = require("fs").readFileSync(process.env.JS, "utf8");
const m = src.match(/function api\(action, opts\) \{[\s\S]*?\n  \}\n/);
if (!m) { console.error("FAIL: api() not found in setup.js"); process.exit(1); }
global.setTimeout = (f) => f();
global.AbortController = undefined;
let calls = 0;
const reply = (status, body) => Promise.resolve({ status, text: () => Promise.resolve(body) });
eval(m[0]);
(async () => {
  calls = 0;
  global.fetch = () => (++calls < 3 ? reply(502, "<center>nginx</center> 502 Bad Gateway") : reply(200, '{"ok":true}'));
  const d = await api("node", { body: "impl=core" });
  if (!d.ok || calls !== 3) throw new Error("nginx 502 must be retried until success (calls=" + calls + ")");
  calls = 0;
  global.fetch = () => (++calls, reply(502, "The process did not produce any response"));
  let threw = false;
  try { await api("complete", { body: "" }); } catch (e) { threw = true; }
  if (!threw || calls !== 1) throw new Error("uhttpd 502 must not be retried (calls=" + calls + ")");
  calls = 0;
  global.fetch = () => (++calls, reply(502, "nginx 502"));
  threw = false;
  try { await api("node", { body: "x" }); } catch (e) { threw = true; }
  if (!threw || calls !== 5) throw new Error("nginx 502 retries must be bounded (calls=" + calls + ")");
  // Network-level failure (keep-alive closed by an nginx reload): one retry
  // for idempotent actions, none for complete/quickstart, none after abort.
  calls = 0;
  global.fetch = () => (++calls === 1 ? Promise.reject(new TypeError("Failed to fetch")) : reply(200, '{"ok":true}'));
  const n = await api("node", { body: "impl=core" });
  if (!n.ok || calls !== 2) throw new Error("network error on 'node' must be retried once (calls=" + calls + ")");
  calls = 0;
  global.fetch = () => (++calls, Promise.reject(new TypeError("Failed to fetch")));
  threw = false;
  try { await api("complete", { body: "" }); } catch (e) { threw = true; }
  if (!threw || calls !== 1) throw new Error("'complete' must never be resent (calls=" + calls + ")");
  calls = 0;
  threw = false;
  try { await api("wifi", { body: "x" }); } catch (e) { threw = true; }
  if (!threw || calls !== 2) throw new Error("network retry must be bounded to one (calls=" + calls + ")");
  calls = 0;
  global.fetch = () => { ++calls; const e = new Error("aborted"); e.name = "AbortError"; return Promise.reject(e); };
  threw = false;
  try { await api("lan", { body: "x" }); } catch (e) { threw = true; }
  if (!threw || calls !== 1) throw new Error("timeouts (AbortError) must not be retried (calls=" + calls + ")");
  console.log("PASS T-SETUP-RETRY");
})().catch((e) => { console.error("FAIL: " + e.message); process.exit(1); });
NODE
