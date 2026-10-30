/* SPDX-License-Identifier: GPL-2.0-only */
(function () {
  var CIRC = 2 * Math.PI * 52;
  var REFRESH_NORMAL_MS = 10000;
  var REFRESH_BUSY_MS = 2000;
  var refreshMs = REFRESH_NORMAL_MS;
  var left = refreshMs / 1000;
  var tipHash = "";
  var timer = null;

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
    if (d > 0) return d + "d " + h + "h";
    if (h > 0) return h + "h " + m + "m";
    return m + "m";
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
  var DISK_LEVEL = {
    healthy: "Healthy",
    attention: "Needs attention",
    at_risk: "At risk",
    failed: "Failed"
  };
  var DISK_ACTION = {
    attention: "Plan to replace the M.2 drive. The node keeps running.",
    at_risk: "Replace the M.2 drive soon and contact support. The node keeps running for now.",
    failed: "The node cannot use this drive. Contact support."
  };
  function diskReason(code, d) {
    var t = d.temp_c != null ? " (" + d.temp_c + " °C)" : "";
    return ({
      drive_missing: "The M.2 drive is not detected.",
      controller_not_live: "The M.2 drive is not responding.",
      read_only: "The blockchain drive has switched to read-only.",
      media_read_only: "The drive has become read-only and can no longer store new blocks.",
      not_mounted: "The blockchain drive is not mounted.",
      filesystem_errors: "The drive's file system has reported errors.",
      smart_unavailable: "Drive health data could not be read.",
      spare_low: "The drive is running out of spare capacity.",
      spare_dropping: "The drive's spare capacity is dropping.",
      wear_out: "The drive has used its rated write life.",
      wear_high: "The drive is past 80 % of its rated write life.",
      media_errors: "The drive has reported data errors.",
      reliability_degraded: "The drive reports that its reliability is degraded.",
      backup_failed: "The drive's internal power-loss backup has failed.",
      temperature_warning: "The drive is running hot" + t + ".",
      temperature_critical: "The drive is too hot" + t + " — check that the router has airflow."
    })[code] || "";
  }
  function renderDisk(d) {
    var v = $("diskHealth"), b = $("diskBanner");
    if (!v || !b) return;
    if (!d || !d.level) { v.textContent = "—"; v.className = "v"; b.hidden = true; return; }
    var parts = [DISK_LEVEL[d.level] || "Unknown"];
    if (d.temp_c != null) parts.push(d.temp_c + " °C");
    if (d.percent_used != null) parts.push(d.percent_used + " % of rated life used");
    if (d.model) parts.push(d.model);
    v.textContent = parts.join(" · ");
    v.className = "v" + (d.level === "at_risk" || d.level === "failed" ? " bad" : "");
    var msgs = (d.reasons || []).map(function (c) { return diskReason(c, d); }).filter(Boolean);
    if (d.level !== "healthy") {
      $("diskBannerTitle").textContent = "M.2 drive: " + (DISK_LEVEL[d.level] || d.level);
      $("diskBannerText").textContent = msgs.concat([DISK_ACTION[d.level] || ""]).join(" ");
      b.className = "warn disk-banner" + (d.level === "attention" ? "" : " bad");
      b.hidden = false;
    } else if (d.power_loss_recent) {
      $("diskBannerTitle").textContent = "Power was lost";
      $("diskBannerText").textContent =
        "The router lost power without shutting down in the last 7 days. " +
        "A small UPS helps protect the blockchain drive.";
      b.className = "warn disk-banner";
      b.hidden = false;
    } else {
      b.hidden = true;
    }
  }

  /* Running a Knots version with a known issue (node-advisory.js): say so
     once per visit, and offer the switch to the fixed Bitcoin Core. */
  var advisoryChecked = false;
  function maybeKnotsAdvisory() {
    var adv = window.KnotsNodeAdvisory;
    if (advisoryChecked || !adv) return;
    advisoryChecked = true;
    try {
      if (sessionStorage.getItem("knots_advisory_seen") === "1") return;
    } catch (e) {
      /* storage blocked: show it each load */
    }
    fetch("/api/node?action=status", { cache: "no-store" })
      .then(function (r) {
        return r.json();
      })
      .then(function (d) {
        var ver = d && d.knots && d.knots.installed ? d.knots.version : "";
        var a = adv.forImpl("knots", ver);
        if (!a || (d && d.active !== "knots")) return;
        try {
          sessionStorage.setItem("knots_advisory_seen", "1");
        } catch (e) {
          /* ignore */
        }
        return adv
          .show(a, {
            coreLabel: "Switch to Bitcoin Core…",
            keepLabel: "Keep Knots for now",
            escape: "keep"
          })
          .then(function (v) {
            if (v === "core") window.location.href = "/node.html";
          });
      })
      .catch(function () {
        /* status only — never block the page */
      });
  }

  function render(data) {
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
    $("behind").textContent = behind ? behind.toLocaleString() + " blocks" : "at tip";
    $("peers").textContent = k.peers != null ? String(k.peers) : "—";
    $("uptime").textContent = fmtUptime(k.uptime_sec);
    $("tipHash").textContent = tipHash || "—";
    $("freeSpace").textContent = s.mounted ? fmtBytes(s.free_bytes) : "not mounted";
    $("version").textContent = data.product_version || "—";
    if ($("buildNumber")) {
      $("buildNumber").textContent = data.build_number || "—";
    }
    $("hostname").textContent = data.hostname || "";

    var impl = data.node_impl || "core";
    var badgeImpl = $("badgeImpl");
    badgeImpl.textContent = impl === "core" ? "Bitcoin Core" : "Bitcoin Knots";
    badgeImpl.className = "badge on";
    if (window.KnotsBrand) {
      window.KnotsBrand.apply(impl);
      window.KnotsBrand.applyBuild(data.product_version, data.build_number);
    }
    if (impl === "knots") maybeKnotsAdvisory();

    var err = $("errorLine");
    var state = $("stateLine");
    var sub = $("subState");
    var badgeSync = $("badgeSync");
    var badgePeers = $("badgePeers");
    var reindexPanel = $("reindexPanel");
    var recovery = data.recovery || {};
    var needsReindex = !!recovery.needs_reindex;
    badgePeers.textContent = (k.peers || 0) + " peers";

    if (reindexPanel) {
      reindexPanel.hidden = !needsReindex || busy;
    }

    if (busy) {
      var op = maint.op || "";
      var msg = maint.message || "Node is initialising";
      var initOps = {
        initializing: 1,
        boot_recover: 1,
        starting: 1
      };
      var isInit = !!initOps[op] || /initialis/i.test(msg) || /initializ/i.test(msg);
      var isReindex = op === "reindex" || /reindex/i.test(msg) || /validat.*chain/i.test(msg);
      state.textContent = msg;
      state.className = "state busy";
      if (isReindex) {
        sub.textContent =
          "Validating blocks already on the M.2 — not re-downloading the chain. " +
          "Keep power on; this can take many hours. This page refreshes automatically.";
        badgeSync.textContent = "reindex";
        setRing(k.running ? prog : 0, "");
      } else if (op === "waiting_clock") {
        sub.textContent =
          "Make sure the router's internet (WAN) cable is plugged in. " +
          "Nothing needs repairing; this page refreshes automatically.";
        badgeSync.textContent = "waiting for time";
        setRing(0, "");
      } else if (isInit) {
        sub.textContent =
          "Please wait — the node is coming up. " +
          "This page refreshes automatically; no action needed.";
        badgeSync.textContent = "initialising";
        setRing(k.running ? prog : 0, "");
      } else {
        sub.textContent =
          "Please wait — switching node software or updating binaries. " +
          "This page will refresh automatically when the node is ready.";
        badgeSync.textContent = "busy";
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
      state.textContent = "Chain database needs repair";
      sub.textContent =
        recovery.hint ||
        "The node cannot start until chainstate is rebuilt from blocks already on the M.2. " +
          "This is not a blockchain re-download.";
      err.hidden = true;
      err.textContent = "";
      badgeSync.textContent = "needs repair";
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
        state.textContent = "Node is initialising";
        state.className = "state busy";
        sub.textContent =
          "Please wait — the node is coming up. This page refreshes automatically.";
        err.hidden = true;
        err.textContent = "";
        badgeSync.textContent = "initialising";
        badgeSync.className = "badge pulse on";
        setRing(0, "");
        setRefreshInterval(REFRESH_BUSY_MS);
      } else if (k.error) {
        err.hidden = false;
        err.className = "error";
        err.textContent = "Error: " + k.error;
        if (!k.running) {
          state.textContent = "Node not running";
          sub.textContent = "Check storage mount and Knots service.";
          badgeSync.textContent = "down";
          badgeSync.className = "badge";
          setRing(0, "bad");
        } else if (prog >= 0.999 && behind === 0) {
          state.textContent = "Synced with the Bitcoin network";
          sub.textContent = "Validating new blocks as they arrive.";
          badgeSync.textContent = "synced";
          badgeSync.className = "badge on";
          setRing(1, "ok");
        } else {
          state.textContent = "Downloading & verifying the blockchain";
          sub.textContent = behind
            ? ("About " + behind.toLocaleString() + " blocks behind network headers.")
            : "Catching up — verification in progress.";
          badgeSync.textContent = "syncing";
          badgeSync.className = "badge pulse on";
          setRing(prog, "");
        }
      } else {
        err.hidden = true;
        err.textContent = "";

        if (!k.running) {
          state.textContent = "Node not running";
          sub.textContent = "Check storage mount and Knots service.";
          badgeSync.textContent = "down";
          badgeSync.className = "badge";
          setRing(0, "bad");
        } else if (prog >= 0.999 && behind === 0) {
          state.textContent = "Synced with the Bitcoin network";
          sub.textContent = "Validating new blocks as they arrive.";
          badgeSync.textContent = "synced";
          badgeSync.className = "badge on";
          setRing(1, "ok");
        } else {
          state.textContent = "Downloading & verifying the blockchain";
          sub.textContent = behind
            ? ("About " + behind.toLocaleString() + " blocks behind network headers.")
            : "Catching up — verification in progress.";
          badgeSync.textContent = "syncing";
          badgeSync.className = "badge pulse on";
          setRing(prog, "");
        }
      }
    }

    $("lowSpace").hidden = !s.low_space;
    renderDisk(data.disk);
    $("updated").textContent = "Updated " + new Date().toLocaleTimeString();
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
        $("stateLine").textContent = "Waiting for node status…";
        $("stateLine").className = "state";
        $("subState").textContent = "The router is up. Status data is still starting.";
        $("errorLine").hidden = false;
        $("errorLine").className = "error";
        $("errorLine").textContent = String(e.message || e);
        setRing(0, "bad");
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
              $("errorLine").textContent = r.message || "Reindex failed to start";
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
    if (el) el.textContent = "Next refresh in " + left + "s";
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
        $("btnCopyHash").textContent = "Copied";
        setTimeout(function () { $("btnCopyHash").textContent = "Copy tip hash"; }, 1200);
      });
    }
  });

  if ($("btnReindex")) {
    $("btnReindex").addEventListener("click", function () {
      var tok = (($("reindexConfirm") && $("reindexConfirm").value) || "").trim();
      if (tok !== "REINDEX") {
        $("errorLine").hidden = false;
        $("errorLine").className = "error";
        $("errorLine").textContent = "Type REINDEX to confirm chain database repair.";
        return;
      }
      // U15 — mutating node action requires router credentials (memory-only)
      var authUser = (($("reindexAuthUser") && $("reindexAuthUser").value) || "").trim();
      var authPass = ($("reindexAuthPass") && $("reindexAuthPass").value) || "";
      if (!authUser || !authPass) {
        $("errorLine").hidden = false;
        $("errorLine").className = "error";
        $("errorLine").textContent = "Enter the router username and password to start the repair.";
        return;
      }
      $("btnReindex").disabled = true;
      $("errorLine").hidden = true;
      $("subState").textContent = "Starting chain database repair…";
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
            $("errorLine").textContent =
              (x.d && (x.d.message || x.d.error)) || "Reindex failed to start";
            return;
          }
          if ($("reindexConfirm")) $("reindexConfirm").value = "";
          if ($("reindexAuthPass")) $("reindexAuthPass").value = "";
          if ($("reindexPanel")) $("reindexPanel").hidden = true;
          $("stateLine").textContent =
            x.d.message ||
            "Validating the chain database — not re-downloading the blockchain.";
          $("stateLine").className = "state busy";
          $("subState").textContent =
            "Keep power on. This page refreshes automatically.";
          $("badgeSync").textContent = "reindex";
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

  tick();
  timer = setInterval(tick, refreshMs);
  setInterval(countdown, 1000);
  countdown();
})();
