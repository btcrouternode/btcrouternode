/* SPDX-License-Identifier: GPL-2.0-only */
(function () {
  function T(k, v) { return window.KnotsI18n ? window.KnotsI18n.t(k, v) : k; }
  /* T(k) when the catalogue has k, else null (server text is the fallback). */
  function Tk(k, v) { var s = T(k, v); return s === k ? null : s; }

  var CIRC = 2 * Math.PI * 52;
  var REFRESH_NORMAL_MS = 10000;
  var REFRESH_BUSY_MS = 2000;
  var refreshMs = REFRESH_NORMAL_MS;
  var left = refreshMs / 1000;
  var tipHash = "";
  var timer = null;
  var lastData = null;    /* last /api/status reply — re-drawn on language change */
  var lastAt = null;
  var lastFetchErr = null;

  function $(id) { return document.getElementById(id); }

  function fmtBytes(n) {
    n = Number(n) || 0;
    var u = ["B", "KB", "MB", "GB", "TB"];
    var i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? String(n) : n.toFixed(1)) + " " + u[i];
  }

  function fmtUptime(sec) {
    sec = Number(sec) || 0;
    var d = Math.floor(sec / 86400);
    var h = Math.floor((sec % 86400) / 3600);
    var m = Math.floor((sec % 3600) / 60);
    if (d > 0) return T("status.uptime.days_hours", { d: d, h: h });
    if (h > 0) return T("status.uptime.hours_minutes", { h: h, m: m });
    return T("status.uptime.minutes", { m: m });
  }

  function setRing(pct, cls) {
    var el = document.querySelector(".ring-fg");
    if (!el) return;
    var p = Math.max(0, Math.min(1, pct));
    el.style.strokeDashoffset = String(CIRC * (1 - p));
    el.classList.remove("ok", "bad");
    if (cls) el.classList.add(cls);
  }

  function setRefreshInterval(ms) {
    if (ms === refreshMs) return;
    refreshMs = ms;
    left = Math.ceil(refreshMs / 1000);
    if (timer) clearInterval(timer);
    timer = setInterval(tick, refreshMs);
  }

  /* M.2 drive health (/api/status .disk from disk-health.sh). Text only —
     values come from the drive, never inserted as HTML. */
  var DISK_LEVELS = { healthy: 1, attention: 1, at_risk: 1, failed: 1 };
  function diskLevel(level) {
    return DISK_LEVELS[level] ? T("status.disk.level." + level) : null;
  }
  function diskAction(level) {
    return (level === "attention" || level === "at_risk" || level === "failed")
      ? T("status.disk.action." + level) : "";
  }
  var DISK_REASONS = {
    drive_missing: 1, controller_not_live: 1, read_only: 1, media_read_only: 1,
    not_mounted: 1, filesystem_errors: 1, smart_unavailable: 1, spare_low: 1,
    spare_dropping: 1, wear_out: 1, wear_high: 1, media_errors: 1,
    reliability_degraded: 1, backup_failed: 1, temperature_warning: 1,
    temperature_critical: 1
  };
  function diskReason(code, d) {
    if (!DISK_REASONS[code]) return "";
    if ((code === "temperature_warning" || code === "temperature_critical") && d.temp_c != null) {
      return T("status.disk.reason." + code + "_temp", { temp: d.temp_c });
    }
    return T("status.disk.reason." + code);
  }
  function renderDisk(d) {
    var v = $("diskHealth"), b = $("diskBanner");
    if (!v || !b) return;
    if (!d || !d.level) { v.textContent = "—"; v.className = "v"; b.hidden = true; return; }
    var parts = [diskLevel(d.level) || T("status.disk.level.unknown")];
    if (d.temp_c != null) parts.push(d.temp_c + " °C");
    if (d.percent_used != null) parts.push(T("status.disk.life_used", { pct: d.percent_used }));
    if (d.model) parts.push(d.model);
    v.textContent = parts.join(" · ");
    v.className = "v" + (d.level === "at_risk" || d.level === "failed" ? " bad" : "");
    var msgs = (d.reasons || []).map(function (c) { return diskReason(c, d); }).filter(Boolean);
    if (d.level !== "healthy") {
      $("diskBannerTitle").textContent =
        T("status.disk.banner_title", { level: diskLevel(d.level) || d.level });
      $("diskBannerText").textContent = msgs.concat([diskAction(d.level)]).join(" ");
      b.className = "warn disk-banner" + (d.level === "attention" ? "" : " bad");
      b.hidden = false;
    } else if (d.power_loss_recent) {
      $("diskBannerTitle").textContent = T("status.disk.power_lost.title");
      $("diskBannerText").textContent = T("status.disk.power_lost.body");
      b.className = "warn disk-banner";
      b.hidden = false;
    } else {
      b.hidden = true;
    }
  }

  /* The router's busy / error / hint texts are English. Show the catalogue
     text for a known message, op or code; otherwise the router's own text. */
  var MAINT_MSG = {
    "Node is initialising — waiting for M.2 storage.": "status.op.initializing_storage",
    "Node is initialising — loading and verifying the chain database. This can take a few minutes after power loss.":
      "status.op.initializing_verify",
    "Node is initialising — starting Bitcoin. Status will update when ready.":
      "status.op.initializing_start",
    "Rebuilding block index and chain database — not re-downloading the blockchain":
      "status.op.reindex_full"
  };
  function maintText(op, msg) {
    if (msg && MAINT_MSG[msg]) return T(MAINT_MSG[msg]);
    return (op && Tk("status.op." + op)) || msg || T("status.state.initialising");
  }
  function nodeErrText(code) {
    var s = Tk("status.error." + code);
    if (s) return s + " (" + code + ")";
    if (/^knots_status_/.test(code)) {
      return T("status.error.service_state", { state: code.replace(/^knots_status_/, "") });
    }
    return T("status.error.generic", { code: code });
  }
  /* /api/node error reply → catalogue text by error code, else the router's text */
  function apiErr(d, fallbackKey) {
    var code = d && d.error;
    return (code && Tk("api.node." + code)) || (d && (d.message || d.error)) || T(fallbackKey);
  }

  function render(data, at) {
    lastData = data;
    lastAt = at || new Date();
    lastFetchErr = null;
    var k = data.knots || {};
    var s = data.storage || {};
    var maint = data.maintenance || {};
    var busy = !!maint.active;
    var prog = Number(k.verification_progress) || 0;
    var pct = Math.round(prog * 1000) / 10;
    var blocks = Number(k.blocks) || 0;
    var headers = Number(k.headers) || 0;
    var behind = Math.max(0, headers - blocks);
    tipHash = k.best_block_hash || "";

    $("syncPct").textContent = (pct > 100 ? 100 : pct).toFixed(pct < 10 ? 1 : 0) + "%";
    $("blocks").textContent = k.blocks != null ? String(k.blocks) : "—";
    $("headers").textContent = k.headers != null ? String(k.headers) : "—";
    $("behind").textContent = behind
      ? T("status.behind.blocks", { n: behind.toLocaleString() })
      : T("status.behind.at_tip");
    $("peers").textContent = k.peers != null ? String(k.peers) : "—";
    $("uptime").textContent = fmtUptime(k.uptime_sec);
    $("tipHash").textContent = tipHash || "—";
    $("freeSpace").textContent = s.mounted ? fmtBytes(s.free_bytes) : T("status.storage.not_mounted");
    $("version").textContent = data.product_version || "—";
    if ($("buildNumber")) {
      $("buildNumber").textContent = data.build_number || "—";
    }
    $("hostname").textContent = data.hostname || "";

    var impl = "core"; /* Bitcoin Core only since build 120 */
    var badgeImpl = $("badgeImpl");
    badgeImpl.textContent = "Bitcoin Core";
    badgeImpl.className = "badge on";
    if (window.KnotsBrand) {
      window.KnotsBrand.apply(impl);
      window.KnotsBrand.applyBuild(data.product_version, data.build_number);
    }

    var err = $("errorLine");
    var state = $("stateLine");
    var sub = $("subState");
    var badgeSync = $("badgeSync");
    var badgePeers = $("badgePeers");
    var reindexPanel = $("reindexPanel");
    var recovery = data.recovery || {};
    var needsReindex = !!recovery.needs_reindex;
    badgePeers.textContent = T("status.badge.peers", { n: k.peers || 0 });

    if (reindexPanel) {
      reindexPanel.hidden = !needsReindex || busy;
    }

    if (busy) {
      var op = maint.op || "";
      var msg = maint.message || "Node is initialising"; /* for the checks below only */
      var initOps = {
        initializing: 1,
        boot_recover: 1,
        starting: 1
      };
      var isInit = !!initOps[op] || /initialis/i.test(msg) || /initializ/i.test(msg);
      var isReindex = op === "reindex" || /reindex/i.test(msg) || /validat.*chain/i.test(msg);
      state.textContent = maintText(op, maint.message);
      state.className = "state busy";
      if (isReindex) {
        sub.textContent = T("status.sub.reindex");
        badgeSync.textContent = T("status.badge.reindex");
        setRing(k.running ? prog : 0, "");
      } else if (op === "waiting_clock") {
        sub.textContent = T("status.sub.waiting_clock");
        badgeSync.textContent = T("status.badge.waiting_clock");
        setRing(0, "");
      } else if (isInit) {
        sub.textContent = T("status.sub.initialising");
        badgeSync.textContent = T("status.badge.initialising");
        setRing(k.running ? prog : 0, "");
      } else {
        sub.textContent = T("status.sub.busy");
        badgeSync.textContent = T("status.badge.busy");
        setRing(k.running ? prog : 0, "");
      }
      err.hidden = true;
      err.textContent = "";
      err.className = "error";
      badgeSync.className = "badge pulse on";
      setRefreshInterval(REFRESH_BUSY_MS);
    } else if (needsReindex) {
      state.className = "state";
      setRefreshInterval(REFRESH_NORMAL_MS);
      state.textContent = T("status.reindex.title");
      sub.textContent = recovery.hint
        ? (Tk("status.recovery." + (recovery.kind || "")) || recovery.hint)
        : T("status.recovery.chainstate");
      err.hidden = true;
      err.textContent = "";
      badgeSync.textContent = T("status.badge.needs_repair");
      badgeSync.className = "badge";
      setRing(0, "bad");
    } else {
      state.className = "state";
      setRefreshInterval(REFRESH_NORMAL_MS);

      // Legacy stub / race: never show raw "starting" / rpc_* as Error:
      var softErr = {
        starting: 1,
        rpc_cookie_missing: 1,
        bitcoind_rpc_unreachable: 1,
        storage_not_mounted: 1,
        knots_status_starting: 1,
        knots_status_recovering: 1,
        knots_status_stopped: 1
      };
      if (k.error && softErr[k.error] && !k.running) {
        state.textContent = T("status.state.initialising");
        state.className = "state busy";
        sub.textContent = T("status.sub.coming_up");
        err.hidden = true;
        err.textContent = "";
        badgeSync.textContent = T("status.badge.initialising");
        badgeSync.className = "badge pulse on";
        setRing(0, "");
        setRefreshInterval(REFRESH_BUSY_MS);
      } else if (k.error) {
        err.hidden = false;
        err.className = "error";
        err.textContent = nodeErrText(k.error);
        if (!k.running) {
          state.textContent = T("status.state.down");
          sub.textContent = T("status.sub.down");
          badgeSync.textContent = T("status.badge.down");
          badgeSync.className = "badge";
          setRing(0, "bad");
        } else if (prog >= 0.999 && behind === 0) {
          state.textContent = T("status.state.synced");
          sub.textContent = T("status.sub.synced");
          badgeSync.textContent = T("status.badge.synced");
          badgeSync.className = "badge on";
          setRing(1, "ok");
        } else {
          state.textContent = T("status.state.syncing");
          sub.textContent = behind
            ? T("status.sub.behind", { n: behind.toLocaleString() })
            : T("status.sub.catching_up");
          badgeSync.textContent = T("status.badge.syncing");
          badgeSync.className = "badge pulse on";
          setRing(prog, "");
        }
      } else {
        err.hidden = true;
        err.textContent = "";

        if (!k.running) {
          state.textContent = T("status.state.down");
          sub.textContent = T("status.sub.down");
          badgeSync.textContent = T("status.badge.down");
          badgeSync.className = "badge";
          setRing(0, "bad");
        } else if (prog >= 0.999 && behind === 0) {
          state.textContent = T("status.state.synced");
          sub.textContent = T("status.sub.synced");
          badgeSync.textContent = T("status.badge.synced");
          badgeSync.className = "badge on";
          setRing(1, "ok");
        } else {
          state.textContent = T("status.state.syncing");
          sub.textContent = behind
            ? T("status.sub.behind", { n: behind.toLocaleString() })
            : T("status.sub.catching_up");
          badgeSync.textContent = T("status.badge.syncing");
          badgeSync.className = "badge pulse on";
          setRing(prog, "");
        }
      }
    }

    $("lowSpace").hidden = !s.low_space;
    renderDisk(data.disk);
    $("updated").textContent = T("status.updated", { time: lastAt.toLocaleTimeString() });
  }

  function showFetchError(msg) {
    lastData = null;
    lastFetchErr = msg;
    $("stateLine").textContent = T("status.state.waiting");
    $("stateLine").className = "state";
    $("subState").textContent = T("status.sub.waiting");
    $("errorLine").hidden = false;
    $("errorLine").className = "error";
    $("errorLine").textContent = msg;
    setRing(0, "bad");
  }

  function tick() {
    var ac = typeof AbortController !== "undefined" ? new AbortController() : null;
    var to = setTimeout(function () {
      if (ac) ac.abort();
    }, 8000);
    var opts = { cache: "no-store" };
    if (ac) opts.signal = ac.signal;
    fetch("/api/status", opts)
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (data) {
        render(data);
        left = Math.ceil(refreshMs / 1000);
      })
      .catch(function (e) {
        showFetchError(String(e.message || e));
      })
      .then(function () {
        clearTimeout(to);
      });
  }

  /* L3 — reindex starts detached; surface the worker's verdict (last_op). */
  function watchReindexStart() {
    var t0 = Date.now();
    function again() {
      fetch("/api/node?action=status", { cache: "no-store" })
        .then(function (r) {
          return r.json();
        })
        .then(function (st) {
          var r = st && st.last_op;
          if (r && r.op === "reindex_chainstate" && r.state && r.state !== "running") {
            if (r.state !== "ok") {
              $("errorLine").hidden = false;
              $("errorLine").className = "error";
              $("errorLine").textContent = T("status.reindex.start_failed");
            }
            return;
          }
          if (Date.now() - t0 < 900000) setTimeout(again, 5000);
        })
        .catch(function () {
          if (Date.now() - t0 < 900000) setTimeout(again, 5000);
        });
    }
    setTimeout(again, 3000);
  }

  function countdown() {
    var el = $("refreshIn");
    if (el) el.textContent = T("status.refresh_in", { s: left });
    left -= 1;
    if (left < 0) left = 0;
  }

  $("btnRefresh").addEventListener("click", function () {
    tick();
  });
  $("btnCopyHash").addEventListener("click", function () {
    if (!tipHash) return;
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(tipHash).then(function () {
        $("btnCopyHash").textContent = T("status.copied");
        setTimeout(function () { $("btnCopyHash").textContent = T("status.copy_hash"); }, 1200);
      });
    }
  });

  if ($("btnReindex")) {
    $("btnReindex").addEventListener("click", function () {
      var tok = (($("reindexConfirm") && $("reindexConfirm").value) || "").trim();
      if (tok !== "REINDEX") {
        $("errorLine").hidden = false;
        $("errorLine").className = "error";
        $("errorLine").textContent = T("status.reindex.type_word", { word: "REINDEX" });
        return;
      }
      // U15 — mutating node action requires router credentials (memory-only)
      var authUser = (($("reindexAuthUser") && $("reindexAuthUser").value) || "").trim();
      var authPass = ($("reindexAuthPass") && $("reindexAuthPass").value) || "";
      if (!authUser || !authPass) {
        $("errorLine").hidden = false;
        $("errorLine").className = "error";
        $("errorLine").textContent = T("status.reindex.need_auth");
        return;
      }
      $("btnReindex").disabled = true;
      $("errorLine").hidden = true;
      $("subState").textContent = T("status.reindex.starting");
      var body =
        "confirm=REINDEX" +
        "&user=" + encodeURIComponent(authUser) +
        "&password=" + encodeURIComponent(authPass);
      fetch("/api/node?action=reindex_chainstate", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: body,
        cache: "no-store"
      })
        .then(function (r) {
          return r.json().then(function (d) {
            return { okHttp: r.ok, d: d };
          });
        })
        .then(function (x) {
          $("btnReindex").disabled = false;
          if (!x.d || !x.d.ok) {
            $("errorLine").hidden = false;
            $("errorLine").className = "error";
            $("errorLine").textContent = apiErr(x.d, "status.reindex.start_failed");
            return;
          }
          if ($("reindexConfirm")) $("reindexConfirm").value = "";
          if ($("reindexAuthPass")) $("reindexAuthPass").value = "";
          if ($("reindexPanel")) $("reindexPanel").hidden = true;
          $("stateLine").textContent = T("status.reindex.accepted");
          $("stateLine").className = "state busy";
          $("subState").textContent = T("status.reindex.keep_power");
          $("badgeSync").textContent = T("status.badge.reindex");
          $("badgeSync").className = "badge pulse on";
          setRefreshInterval(REFRESH_BUSY_MS);
          tick();
          watchReindexStart();
        })
        .catch(function (e) {
          $("btnReindex").disabled = false;
          $("errorLine").hidden = false;
          $("errorLine").className = "error";
          $("errorLine").textContent = String(e.message || e);
        });
    });
  }

  /* Language loaded or changed: re-draw the text this script wrote. */
  if (window.KnotsI18n && window.KnotsI18n.onChange) {
    window.KnotsI18n.onChange(function () {
      if (lastData) render(lastData, lastAt);
      else if (lastFetchErr) showFetchError(lastFetchErr);
      else {
        $("stateLine").textContent = T("status.loading");
        $("updated").textContent = T("status.waiting_first");
        $("badgePeers").textContent = T("status.badge.peers_label");
      }
    });
  }

  tick();
  timer = setInterval(tick, refreshMs);
  setInterval(countdown, 1000);
  countdown();
})();
