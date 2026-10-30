#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# T-WAIT-PROBE — progress-wait.js probe behaviour (review H1 / H2).
#  H1: a failing status CGI while nginx /api/alive still answers is NOT a
#      reboot; runWait must not finish (reset.js would clear markers mid-reset).
#      Once /api/alive itself fails and comes back, it must finish.
#  H2: handoffWhenReady keeps at most one probe round in flight no matter how
#      many watchOnline ticks fire during a long outage.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PW="$ROOT/files/www/knots/progress-wait.js"

PW="$PW" ONLY_H2="${ONLY_H2:-}" node <<'NODE'
const fs = require("fs");
const vm = require("vm");
const src = fs.readFileSync(process.env.PW, "utf8");

/* Deterministic fake clock. */
let now = 0, seq = 0;
const timers = new Map();
function addTimer(fn, ms, repeat) {
  const id = ++seq;
  timers.set(id, { fn, at: now + (ms || 0), ms: ms || 0, repeat });
  return id;
}
function clear(id) { timers.delete(id); }
async function flush() { for (let i = 0; i < 20; i++) await Promise.resolve(); }
async function advance(ms) {
  const end = now + ms;
  for (;;) {
    let next = null;
    for (const [id, t] of timers) if (t.at <= end && (!next || t.at < next[1].at)) next = [id, t];
    if (!next) break;
    const [id, t] = next;
    now = t.at;
    if (t.repeat) t.at = now + Math.max(t.ms, 1); else timers.delete(id);
    t.fn();
    await flush();
  }
  now = end;
  await flush();
}

function makeEnv(fetchImpl) {
  const el = () => ({ textContent: "", innerHTML: "", style: {}, hidden: false,
    classList: { add() {}, remove() {}, toggle() {} },
    setAttribute() {}, removeAttribute() {}, appendChild() {}, querySelectorAll: () => [] });
  const ctx = {
    console, Promise, JSON, Math, Error,
    Date: { now: () => now },
    setTimeout: (f, ms) => addTimer(f, ms, false),
    clearTimeout: clear,
    setInterval: (f, ms) => addTimer(f, ms, true),
    clearInterval: clear,
    fetch: fetchImpl,
    document: { getElementById: () => el(), createElement: () => el(), title: "" },
    sessionStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    location: { protocol: "http:", hostname: "rnode.local", href: "http://rnode.local/reset.html", search: "" },
    navigator: {},
  };
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(src, ctx);
  return ctx;
}

const ok = (body) => Promise.resolve({ ok: true, json: () => Promise.resolve(body) });
const fail = () => Promise.reject(new Error("net"));

async function h1() {
  let aliveUp = true, finished = 0;
  const env = makeEnv((url) => {
    if (url.includes("/api/alive")) return aliveUp ? ok({ ok: true, alive: true }) : fail();
    return Promise.resolve({ ok: false, json: () => Promise.resolve({}) }); /* CGI 502 */
  });
  env.KnotsProgressWait.runWait({
    probeDelayMs: 0, expectedMs: 600000,
    shouldFinish: () => false, onFinish: () => { finished++; },
  });
  await advance(30000);
  if (finished) throw new Error("H1: finished while nginx /api/alive was still up (CGI only slow)");
  aliveUp = false;
  await advance(10000);
  if (finished) throw new Error("H1: finished while router was down");
  aliveUp = true;
  await advance(10000);
  if (finished !== 1) throw new Error("H1: did not finish after real down→up (finished=" + finished + ")");
  for (const id of [...timers.keys()]) clear(id);
  console.log("PASS H1 slow CGI is not a reboot; real down→up finishes");
}

async function h2() {
  now = 0;
  let inflight = 0, maxInflight = 0, calls = 0;
  /* Alive never answers within the window: a long LAN outage. Each fetch
     hangs 4s (inside the 5s abort) so overlapping rounds would show up. */
  const env = makeEnv(() => {
    calls++; inflight++; maxInflight = Math.max(maxInflight, inflight);
    return new Promise((_, rej) => addTimer(() => { inflight--; rej(new Error("down")); }, 4000, false));
  });
  env.KnotsWaitHandoff = {
    decideDest: () => ({ url: "x", label: "x" }),
    canNavigate: () => false,
  };
  const h = env.KnotsProgressWait.handoffWhenReady("reset", {
    requireDown: false, timeoutMs: 1e9, intervalMs: 1500,
  });
  await advance(120000);
  h.stop();
  for (const id of [...timers.keys()]) clear(id);
  /* watchOnline itself: 1 probe per 1.5s tick (each hangs 4s → ≤3 overlap).
     handoff rounds must add at most one more concurrent chain. */
  if (maxInflight > 6) throw new Error("H2: " + maxInflight + " concurrent probes (chains multiplying)");
  if (calls > 400) throw new Error("H2: " + calls + " probes in 120s (unbounded growth)");
  console.log("PASS H2 handoff probes bounded (max in-flight " + maxInflight + ", " + calls + " calls/120s)");
}

(async () => { if (!process.env.ONLY_H2) await h1(); await h2(); })().catch((e) => { console.error("FAIL: " + e.message); process.exit(1); });
NODE
echo "PASS T-WAIT-PROBE"
