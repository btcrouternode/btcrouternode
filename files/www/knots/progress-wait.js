/* SPDX-License-Identifier: GPL-2.0-only */
/* Shared full-page progress wait (factory reset + firmware upgrade). */
(function (global) {
  /* Strings: i18n/en.js is bundled with the page, so T() never needs the
     network — the router may be rebooting while this page runs. */
  function T(k, v) { return global.KnotsI18n ? global.KnotsI18n.t(k, v) : k; }

  var LAN_DROP_EN =
    "Your computer may show Ethernet or Wi-Fi as disconnected while the router " +
    "restarts. That is normal. Leave the cable plugged in. If Ubuntu turns LAN " +
    "off, click it back on. Do not power-cycle the router.";
  /* In the current language (LAN_DROP below stays the English text). */
  function lanDrop() {
    return global.KnotsI18n ? T("wait.lan_drop") : LAN_DROP_EN;
  }
  var LAN_DROP = LAN_DROP_EN;

  function $(id) {
    return document.getElementById(id);
  }

  /* Text drawn once (hint / copy / warning): remember how to draw it and draw
     it again when the language loads (KnotsI18n.onChange). */
  var drawn = {};
  function draw(id, fn) {
    var el = $(id);
    if (!el || typeof fn !== "function") return;
    drawn[id] = fn;
    fn(el);
  }
  function redrawAll() {
    Object.keys(drawn).forEach(function (id) {
      var el = $(id);
      if (el) {
        try { drawn[id](el); } catch (e) {}
      }
    });
    relabelSteps();
  }
  if (global.KnotsI18n && global.KnotsI18n.onChange) {
    global.KnotsI18n.onChange(redrawAll);
  }

  /* Step label in the current language (English label = fallback). */
  function stepLabel(s) {
    if (!s) return "";
    return s.key && global.KnotsI18n ? T(s.key) : s.label;
  }

  /*
   * holdMs is how long the wait page keeps a step "In progress" when the LAN
   * is down (API cannot confirm). A LAN drop must NOT jump to the last step
   * (that marked every earlier bar Done and left Initialising hung — F156).
   *
   * Serial 2026-09-16, three sysupgrade -n to .61 (kernel timestamps):
   *   lxc-stop 60/60/60s; eMMC 19/19/18s; procd 15.3s; br-lan lan3
   *   forwarding 413.3 / 412.7 / 413.0s; Wi-Fi APs 539s then 503s.
   * Keep-config .60 LAN forwarding was 51s (uci-defaults do not re-run).
   * stop_node stays 90s (graceful-stop budget; these -n runs were 2–4s).
   */
  var STEP_SETS = {
    /* Factory reset: first-boot after overlay wipe matches -n LAN (~413s). */
    reset: [
      { id: "stop_node", key: "wait.step.stop_node", label: "Stopping BTC Node", holdMs: 90000 },
      { id: "stop_lxc", key: "wait.step.stop_services", label: "Stopping node services", holdMs: 65000 },
      { id: "reset_settings", key: "wait.step.reset_settings", label: "Resetting Router Settings", holdMs: 20000 },
      { id: "restarting", key: "wait.step.restarting", label: "Restarting Router", holdMs: 25000 },
      { id: "starting", key: "wait.step.starting", label: "Starting Network Services", holdMs: 420000 },
      { id: "init", key: "wait.step.open_setup", label: "Opening Setup", holdMs: 30000 }
    ],
    /* Reset-settings firmware: Updating covers flash + reboot + first-boot LAN. */
    upgrade: [
      { id: "stop_node", key: "wait.step.stop_node", label: "Stopping BTC Node", holdMs: 90000 },
      { id: "stop_lxc", key: "wait.step.stop_services", label: "Stopping node services", holdMs: 65000 },
      { id: "updating", key: "wait.step.updating", label: "Updating Router", holdMs: 450000 },
      { id: "init", key: "wait.step.open_setup", label: "Opening Setup", holdMs: 30000 }
    ],
    /* In-place keep-settings: same four stages; last bar opens Node Status. */
    upgradeKeep: [
      { id: "stop_node", key: "wait.step.stop_node", label: "Stopping BTC Node", holdMs: 90000 },
      { id: "stop_lxc", key: "wait.step.stop_services", label: "Stopping node services", holdMs: 65000 },
      { id: "updating", key: "wait.step.updating", label: "Updating Router", holdMs: 90000 },
      { id: "init", key: "wait.step.open_status", label: "Opening Node Status", holdMs: 30000 }
    ]
  };

  var activeStepper = null;

  /* extra: text, or a function returning text (re-drawn on language load). */
  function showLinkDown(extra) {
    var detail = $("waitProgressDetail");
    draw("waitHint", function (hint) {
      var x = typeof extra === "function" ? extra() : extra;
      hint.textContent = x ? x + " " + lanDrop() : lanDrop();
    });
    if (detail && !activeStepper) {
      detail.textContent = T("wait.lan_back");
    }
  }

  /* D2: the host this tab reached the router by (shell.js KnotsIue.host);
     rnode.local when shell.js is absent (host tests). */
  function namedHost() {
    return typeof window !== "undefined" && window.KnotsIue && window.KnotsIue.host
      ? window.KnotsIue.host()
      : "rnode.local";
  }
  var NAMED_HOST = namedHost();

  function namedAliveUrl() {
    return "http://" + namedHost() + "/api/alive?t=" + Date.now();
  }

  function probeNamedAlive() {
    var ctrl = typeof AbortController !== "undefined" ? new AbortController() : null;
    var to = setTimeout(function () {
      if (ctrl) ctrl.abort();
    }, 5000);
    var fetchOpts = { cache: "no-store", mode: "cors" };
    if (ctrl) fetchOpts.signal = ctrl.signal;
    return fetch(namedAliveUrl(), fetchOpts).then(
      function (r) {
        clearTimeout(to);
        if (!r.ok) throw new Error("down");
        return r.json();
      },
      function (e) {
        clearTimeout(to);
        throw e;
      }
    ).then(function (d) {
      if (!d || !d.ok) throw new Error("bad");
      return d;
    });
  }

  /**
   * Poll http://rnode.local/api/alive until nginx answers (U13/U17).
   * requireDown: wait until the host has failed at least once (reboot), then
   * the first success opens the destination — do not leave during sysupgrade.
   */
  function watchOnline(opts) {
    opts = opts || {};
    var interval = opts.intervalMs || 1500;
    var requireDown = opts.requireDown !== false;
    var sawDown = false;
    var stopped = false;
    var timer = null;

    function tick() {
      if (stopped) return;
      probeNamedAlive()
        .then(function (d) {
          if (stopped) return;
          if (requireDown && !sawDown) {
            if (typeof opts.onTick === "function") {
              opts.onTick({ sawDown: false, up: true });
            }
            return;
          }
          stopped = true;
          if (timer) clearInterval(timer);
          if (typeof opts.onUp === "function") opts.onUp(d);
        })
        .catch(function () {
          if (stopped) return;
          sawDown = true;
          if (typeof opts.onTick === "function") {
            opts.onTick({ sawDown: true, up: false });
          }
        });
    }

    tick();
    timer = setInterval(tick, interval);
    return {
      stop: function () {
        stopped = true;
        if (timer) clearInterval(timer);
      }
    };
  }

  function jsonGet(url) {
    return fetch(url, { cache: "no-store", mode: "cors" }).then(function (r) {
      if (!r.ok) throw new Error("http");
      return r.json();
    });
  }

  function statusPayloadOk(d) {
    return !!(d && typeof d.product_version === "string" && d.product_version);
  }

  function probeSetupPageHttp() {
    return fetch("http://" + namedHost() + "/setup.html?step=0&t=" + Date.now(), {
      cache: "no-store",
      redirect: "manual"
    }).then(function (r) {
      if (r.type === "opaqueredirect") throw new Error("redirect");
      if (r.status >= 300 && r.status < 400) throw new Error("redirect");
      if (!r.ok) throw new Error("http");
      return true;
    });
  }

  function collectHandoffProbes(kind) {
    var probes = {
      alive: false,
      upgradeLive: false,
      factoryResetLive: false,
      setupComplete: undefined,
      statusHttps: false,
      statusHttp: false,
      setupPageHttp: false,
      productVersion: ""
    };
    return probeNamedAlive()
      .then(function () {
        probes.alive = true;
      })
      .catch(function () {
        probes.alive = false;
      })
      .then(function () {
        return jsonGet("/api/setup?action=status")
          .then(function (d) {
            if (!d) return;
            if (d.complete === false) probes.setupComplete = false;
            else if (d.complete === true) probes.setupComplete = true;
            probes.upgradeLive = !!(probes.upgradeLive || d.upgrade_live);
            probes.factoryResetLive = !!(probes.factoryResetLive || d.factory_reset_live);
          })
          .catch(function () {
            /* setup API may 404 on HTTPS after complete; wait tab is HTTP */
          });
      })
      .then(function () {
        return jsonGet("/api/settings?action=status")
          .then(function (d) {
            if (!d) return;
            probes.upgradeLive = !!(probes.upgradeLive || d.upgrade_live);
            /* settings-api exposes factory_reset_active (includes /etc pending).
               Pending survives reboot — do not treat it as still applying. */
            if (d.product_version) probes.productVersion = d.product_version;
            if (probes.setupComplete === undefined && d.ok && d.product_version) {
              probes.setupComplete = true;
            }
          })
          .catch(function () {
            /* settings still coming up */
          });
      })
      .then(function () {
        if (kind === "upgradeKeep") {
          return jsonGet("https://" + namedHost() + "/api/status?t=" + Date.now())
            .then(function (d) {
              if (statusPayloadOk(d)) {
                probes.statusHttps = true;
                if (d.product_version) probes.productVersion = d.product_version;
              }
            })
            .catch(function () {
              return jsonGet("http://" + namedHost() + "/api/status?t=" + Date.now())
                .then(function (d) {
                  if (statusPayloadOk(d)) probes.statusHttp = true;
                })
                .catch(function () {
                  /* neither status probe ready */
                });
            });
        }
        return probeSetupPageHttp()
          .then(function () {
            probes.setupPageHttp = true;
          })
          .catch(function () {
            /* Setup HTML not on HTTP yet (or 302 to HTTPS) */
          });
      })
      .then(function () {
        return probes;
      });
  }

  function handoffMessage(dest, reason) {
    if (reason === "https_untrusted") {
      return T("wait.handoff.https_untrusted");
    }
    if (dest && dest.page === "setup") {
      return T("wait.handoff.setup", { url: "http://" + namedHost() });
    }
    return T("wait.handoff.status", { url: "https://" + namedHost() });
  }

  /* Destination name for messages (wait-handoff.js keeps English labels). */
  function destName(dest) {
    if (dest && dest.page === "setup") return T("wait.dest.setup");
    if (dest && dest.page === "status") return T("wait.dest.status");
    return (dest && dest.label) || "";
  }

  function showHandoffStay(dest, probes) {
    var H = global.KnotsWaitHandoff;
    var reason = H && typeof H.blockedReason === "function" ? H.blockedReason(dest, probes) : "";
    draw("waitHint", function (hint) {
      hint.textContent = handoffMessage(dest, reason);
      if (dest && dest.url && !hint.querySelector("[data-handoff-open]")) {
        hint.appendChild(document.createTextNode(" "));
        var a = document.createElement("a");
        a.setAttribute("data-handoff-open", "1");
        a.className = "btn-primary";
        a.href = dest.url;
        a.textContent = dest.page === "setup" ? T("wait.open_setup") : T("wait.open_status");
        hint.appendChild(a);
      }
    });
    if ($("waitProgressDetail")) {
      $("waitProgressDetail").textContent = handoffMessage(dest, reason);
    }
  }

  /**
   * Stay on the HTTP wait page until the real destination works, then navigate
   * once. Never open HTTPS Setup after -n / factory reset. Never open Node
   * Status until HTTPS /api/status succeeds (keep-settings).
   */
  function handoffWhenReady(kind, opts) {
    opts = opts || {};
    var H = global.KnotsWaitHandoff;
    if (!H) {
      if (typeof opts.onTimeout === "function") opts.onTimeout({ url: "" }, {});
      return { stop: function () {} };
    }
    var requireDown = opts.requireDown === true;
    var sawDown = !!opts.forceFinished;
    var started = Date.now();
    var timeoutMs = opts.timeoutMs != null ? opts.timeoutMs : 90000;
    var offered = false;
    var stopped = false;
    var watcher = null;

    function decorate(probes) {
      probes.sawReboot = sawDown;
      probes.forceFinished = !!opts.forceFinished;
      if (opts.prevVersion && probes.productVersion && probes.productVersion !== opts.prevVersion) {
        probes.versionChanged = true;
      }
      if (opts.startedAt && opts.expectedMs && Date.now() - opts.startedAt >= opts.expectedMs) {
        probes.applyElapsedOk = true;
      }
      return probes;
    }

    /* H2 — at most one probe round in flight and one retry scheduled.
       watchOnline ticks every 1.5s and each tick calls tryOnce; without this
       guard every tick started another self-rescheduling chain. */
    var inFlight = false;
    var retryTimer = null;

    function scheduleRetry() {
      if (stopped || retryTimer) return;
      retryTimer = setTimeout(function () {
        retryTimer = null;
        tryOnce();
      }, 2000);
    }

    function tryOnce() {
      if (stopped || inFlight) return;
      if (retryTimer) {
        clearTimeout(retryTimer);
        retryTimer = null;
      }
      inFlight = true;
      collectHandoffProbes(kind).then(function (probes) {
        inFlight = false;
        if (stopped) return;
        probes = decorate(probes);
        var dest = H.decideDest(kind, probes);
        if (H.canNavigate(dest, probes)) {
          stopped = true;
          if (watcher && watcher.stop) watcher.stop();
          if (typeof opts.onReady === "function") opts.onReady(dest, probes);
          return;
        }
        if (typeof opts.onTick === "function") opts.onTick(dest, probes);
        if (!offered && Date.now() - started > timeoutMs) {
          offered = true;
          showHandoffStay(dest, probes);
          if (typeof opts.onTimeout === "function") opts.onTimeout(dest, probes);
        } else if (!offered) {
          if ($("waitHint") && dest && dest.label) {
            draw("waitHint", function (hint) {
              hint.textContent = T("wait.confirming", { dest: destName(dest) });
            });
          }
        }
        scheduleRetry();
      }, function () {
        inFlight = false;
        scheduleRetry();
      });
    }

    watcher = watchOnline({
      requireDown: requireDown,
      intervalMs: opts.intervalMs || 1500,
      onTick: function (ctx) {
        if (ctx && ctx.sawDown) sawDown = true;
        if (typeof opts.onWatchTick === "function") opts.onWatchTick(ctx);
        if (!requireDown || sawDown) tryOnce();
        else if (opts.forceFinished || opts.prevVersion || opts.expectedMs) {
          tryOnce();
        }
      },
      onUp: function () {
        if (!requireDown) sawDown = true;
        tryOnce();
      }
    });

    return {
      stop: function () {
        stopped = true;
        if (retryTimer) clearTimeout(retryTimer);
        if (watcher && watcher.stop) watcher.stop();
      }
    };
  }

  function stepList(kind) {
    return STEP_SETS[kind] || STEP_SETS.reset;
  }

  function stepIndexOf(defs, id) {
    var i;
    for (i = 0; i < defs.length; i++) {
      if (defs[i].id === id) return i;
    }
    return -1;
  }

  function makeStepper(kind) {
    var defs = stepList(kind);
    var index = 0;
    var began = Date.now();
    var apiIndex = -1;
    var heardApi = false;
    var fillHigh = [];

    function paint() {
      var root = $("waitStepList");
      if (!root) return;
      var items = root.querySelectorAll(".wait-step");
      var elapsed = Date.now() - began;
      var hold = (defs[index] && defs[index].holdMs) || 30000;
      var last = index >= defs.length - 1;
      var fillPct = Math.round((elapsed / hold) * 100);
      if (last) fillPct = Math.min(95, fillPct);
      else fillPct = Math.min(100, fillPct);
      if (fillHigh[index] == null || fillPct > fillHigh[index]) {
        fillHigh[index] = fillPct;
      }
      fillPct = fillHigh[index];
      var remain = Math.max(0, Math.ceil((hold - elapsed) / 1000));
      var i;
      for (i = 0; i < items.length; i++) {
        var el = items[i];
        var fill = el.querySelector(".wait-step-fill");
        var state = el.querySelector(".wait-step-state");
        var track = el.querySelector(".wait-step-track");
        el.classList.remove("is-pending", "is-active", "is-done");
        if (i < index) {
          el.classList.add("is-done");
          fillHigh[i] = 100;
          if (state) state.textContent = T("wait.state.done");
          if (fill) {
            fill.classList.remove("indeterminate");
            fill.style.width = "100%";
          }
          if (track) track.setAttribute("aria-valuenow", "100");
        } else if (i === index) {
          el.classList.add("is-active");
          if (state) {
            state.textContent =
              remain > 0
                ? T("wait.state.active", { s: remain })
                : T("wait.state.still");
          }
          if (fill) {
            fill.classList.remove("indeterminate");
            fill.style.width = fillPct + "%";
          }
          if (track) track.setAttribute("aria-valuenow", String(fillPct));
        } else {
          el.classList.add("is-pending");
          if (state) state.textContent = T("wait.state.waiting");
          if (fill) {
            fill.classList.remove("indeterminate");
            fill.style.width = "0%";
          }
          if (track) track.setAttribute("aria-valuenow", "0");
        }
      }
      var cur = defs[index];
      if (cur && $("waitProgressLabel")) $("waitProgressLabel").textContent = stepLabel(cur);
      if (cur && $("waitProgressDetail")) {
        $("waitProgressDetail").textContent =
          remain > 0
            ? T("wait.detail.active", { step: stepLabel(cur), s: remain })
            : T("wait.detail.still", { step: stepLabel(cur) });
      }
    }

    function goTo(stepId, fromApi) {
      if (!stepId || stepId === "none") return;
      var n = stepIndexOf(defs, stepId);
      if (n < 0) return;
      if (fromApi) {
        heardApi = true;
        if (n < apiIndex) return;
        apiIndex = n;
      }
      /* Never rewind. Keep-settings leaves LAN up, so the API keeps saying
         stop_node for the whole bitcoind stop (~90s). A clock-advanced bar
         must not jump back to the first step (looked like a loop). */
      if (n < index) return;
      if (n !== index) {
        index = n;
        began = Date.now();
      }
      paint();
    }

    function tick(sawDown) {
      var hold = (defs[index] && defs[index].holdMs) || 30000;
      var elapsed = Date.now() - began;
      var apiStale = !heardApi || apiIndex <= index;
      if (sawDown) apiStale = true;
      /* Counters finish this bar when holdMs elapses (LAN up or down). */
      if (elapsed >= hold && index < defs.length - 1) {
        fillHigh[index] = 100;
        index += 1;
        began = Date.now();
      }
      paint();
    }

    return {
      defs: defs,
      goTo: goTo,
      tick: tick,
      paint: paint
    };
  }

  function renderStepList(kind) {
    var root = $("waitStepList");
    if (!root) return;
    var wrap = $("waitProgress");
    if (wrap) wrap.classList.add("has-step-bars");
    var steps = stepList(kind);
    var wantKind = kind || "reset";
    /* Re-building the list resets every bar to 0% (looked like a loop). */
    if (root.getAttribute("data-kind") === wantKind && root.children.length && activeStepper) {
      return;
    }
    root.setAttribute("data-kind", wantKind);
    root.innerHTML = "";
    var i;
    for (i = 0; i < steps.length; i++) {
      var li = document.createElement("li");
      li.className = "wait-step is-pending";
      li.setAttribute("data-step", steps[i].id);
      li.innerHTML =
        '<div class="wait-step-head">' +
        '<span class="wait-step-label"></span>' +
        '<span class="wait-step-state"></span>' +
        "</div>" +
        '<div class="wait-step-track" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">' +
        '<div class="wait-step-fill"></div>' +
        "</div>";
      li.querySelector(".wait-step-label").textContent = stepLabel(steps[i]);
      li.querySelector(".wait-step-state").textContent = T("wait.state.waiting");
      root.appendChild(li);
    }
    activeStepper = makeStepper(kind);
    activeStepper.paint();
  }

  /* Language loaded after the list was drawn: re-label the steps. */
  function relabelSteps() {
    var root = $("waitStepList");
    if (!root) return;
    var defs = stepList(root.getAttribute("data-kind") || "reset");
    var items = root.querySelectorAll(".wait-step");
    for (var i = 0; i < items.length; i++) {
      var id = items[i].getAttribute("data-step");
      var n = stepIndexOf(defs, id);
      var lab = items[i].querySelector(".wait-step-label");
      if (lab && n >= 0) lab.textContent = stepLabel(defs[n]);
    }
    if (activeStepper) activeStepper.paint();
  }

  function applyStep(stepId) {
    if (activeStepper) activeStepper.goTo(stepId, false);
  }

  function applyStatus(d) {
    if (!d) return;
    if (d.progress_step && activeStepper) {
      activeStepper.goTo(d.progress_step, true);
    } else if (d.progress_step) {
      applyStep(d.progress_step);
    }
  }

  function markAllStepsDone() {
    var root = $("waitStepList");
    if (!root) return;
    var items = root.querySelectorAll(".wait-step");
    var i;
    for (i = 0; i < items.length; i++) {
      applyStep(items[items.length - 1].getAttribute("data-step"));
      items[i].classList.remove("is-pending", "is-active");
      items[i].classList.add("is-done");
      var fill = items[i].querySelector(".wait-step-fill");
      var state = items[i].querySelector(".wait-step-state");
      var track = items[i].querySelector(".wait-step-track");
      if (state) state.textContent = T("wait.state.done");
      if (fill) {
        fill.classList.remove("indeterminate");
        fill.style.width = "100%";
      }
      if (track) track.setAttribute("aria-valuenow", "100");
    }
  }

  function setProgress(opts, pct, detail, indeterminate) {
    opts = opts || {};
    var fill = $(opts.fillId || "waitProgressFill");
    var bar = $(opts.barId || "waitProgressBar");
    var label = $(opts.labelId || "waitProgressLabel");
    if (label && opts.title) label.textContent = opts.title;
    if (detail != null && $(opts.detailId || "waitProgressDetail")) {
      $(opts.detailId || "waitProgressDetail").textContent = detail || "";
    }
    if (!fill) return;
    fill.classList.toggle("indeterminate", !!indeterminate);
    if (indeterminate) {
      fill.style.width = "35%";
      if (bar) bar.setAttribute("aria-valuenow", "0");
      return;
    }
    var n = Math.max(0, Math.min(100, pct == null ? 0 : pct));
    fill.style.width = n + "%";
    if (bar) bar.setAttribute("aria-valuenow", String(Math.round(n)));
  }

  function readState(key) {
    try {
      var raw = sessionStorage.getItem(key);
      if (raw) return JSON.parse(raw);
    } catch (e) {
      /* ignore */
    }
    return null;
  }

  function writeState(key, st) {
    try {
      sessionStorage.setItem(key, JSON.stringify(st));
    } catch (e) {
      /* private mode */
    }
  }

  function clearState(key) {
    try {
      sessionStorage.removeItem(key);
    } catch (e) {
      /* ignore */
    }
  }

  /**
   * opts:
   *  storageKey, expectedSeconds, startedAt, title,
   *  progressIds (optional), probeUrl,
   *  isLive(d) -> stay waiting (sysupgrade/reset still this boot),
   *  shouldFinish(d, ctx) -> bool,
   *  onFinish(d),
   *  startingDetail
   * Text options (title, rebootTitle, rebootDetail, finishingDetail,
   * startingDetail) may be functions returning the text in the current
   * language — they are read again whenever the page redraws.
   */
  function runWait(opts) {
    opts = opts || {};
    var expectedMs = Math.max(60, Number(opts.expectedSeconds) || 150) * 1000;
    var started = opts.startedAt || Date.now();
    var sawDown = false;
    var downSince = null;
    var lingered = false;
    var done = false;
    var timer = null;
    var progressTimer = null;
    var key = opts.storageKey || "knotsProgressWait";
    function txt(v) {
      return typeof v === "function" ? v() : v;
    }
    var ui = {
      get title() { return txt(opts.title) || T("wait.in_progress"); },
      get rebootTitle() {
        return txt(opts.rebootTitle) || txt(opts.title) || T("wait.in_progress");
      },
      get rebootDetail() { return txt(opts.rebootDetail) || T("wait.reboot_detail"); },
      get finishingDetail() { return txt(opts.finishingDetail) || T("wait.finishing"); },
      fillId: (opts.progressIds && opts.progressIds.fill) || "waitProgressFill",
      barId: (opts.progressIds && opts.progressIds.bar) || "waitProgressBar",
      labelId: (opts.progressIds && opts.progressIds.label) || "waitProgressLabel",
      detailId: (opts.progressIds && opts.progressIds.detail) || "waitProgressDetail",
      headingId: opts.headingId || "waitTitle",
      warnId: opts.warnId || "waitWarn"
    };

    function applyHeading(title, detail) {
      var h = $(ui.headingId);
      if (h) h.textContent = title || ui.title;
      if (detail && $(ui.warnId)) $(ui.warnId).textContent = detail;
    }

    writeState(key, {
      started: started,
      expectedMs: expectedMs,
      prev: opts.prev || "",
      keepConfig: opts.keepConfig !== false && opts.keepConfig !== 0 && opts.keepConfig !== "0"
    });

    function maybeFinishAfterDown() {
      if (done || !downSince) return;
      var ms = opts.finishMsAfterDown;
      if (ms == null || ms <= 0) return;
      if (Date.now() - downSince < ms) return;
      /* Stay on this document. Navigating while the LAN is down replaces
         this page with the browser “Unable to connect” error (F150). */
      showLinkDown(function () { return txt(opts.rebootDetail); });
      if (!lingered && typeof opts.onDownLinger === "function") {
        lingered = true;
        opts.onDownLinger();
      }
    }

    function finish(d) {
      if (done) return;
      done = true;
      if (timer) clearInterval(timer);
      if (progressTimer) clearInterval(progressTimer);
      clearState(key);
      setProgress(
        { title: ui.title, labelId: ui.labelId, fillId: ui.fillId, barId: ui.barId, detailId: ui.detailId },
        100,
        ui.finishingDetail,
        false
      );
      applyHeading(ui.title, null);
      markAllStepsDone();
      if (typeof opts.onFinish === "function") opts.onFinish(d || {});
    }

    function tickProgress() {
      if (done) return;
      var elapsed = Date.now() - started;
      var pct = Math.min(95, (elapsed / expectedMs) * 100);
      var remain = Math.max(0, Math.ceil((expectedMs - elapsed) / 1000));
      var elapsedSec = Math.round(elapsed / 1000);
      var rebootPhase = elapsed >= expectedMs || (sawDown && elapsed >= 60000);
      if (activeStepper) activeStepper.tick(sawDown);
      var root = $("waitStepList");
      if (root) {
        var items = root.querySelectorAll(".wait-step");
        var doneN = root.querySelectorAll(".wait-step.is-done").length;
        var tot = items.length || 1;
        var stepPct = Math.min(95, Math.round(((doneN + 0.35) / tot) * 100));
        pct = Math.max(pct, stepPct);
      }
      if (rebootPhase) {
        setProgress(
          {
            title: activeStepper ? null : ui.rebootTitle,
            labelId: ui.labelId,
            fillId: ui.fillId,
            barId: ui.barId,
            detailId: ui.detailId
          },
          95,
          activeStepper ? null : ui.rebootDetail,
          true
        );
        applyHeading(ui.rebootTitle, ui.rebootDetail);
      } else {
        setProgress(
          {
            title: activeStepper ? null : ui.title,
            labelId: ui.labelId,
            fillId: ui.fillId,
            barId: ui.barId,
            detailId: ui.detailId
          },
          pct,
          activeStepper
            ? null
            : T("wait.remaining", { remain: remain, elapsed: elapsedSec }),
          false
        );
        applyHeading(ui.title, null);
      }
    }

    function probe() {
      if (done) return;
      var ctrl = typeof AbortController !== "undefined" ? new AbortController() : null;
      var to = setTimeout(function () {
        if (ctrl) ctrl.abort();
      }, 5000);
      var fetchOpts = { cache: "no-store", mode: "cors" };
      if (ctrl) fetchOpts.signal = ctrl.signal;
      /* After the LAN drops, only http://rnode.local counts as "back"
         (HTTPS is a new untrusted CA after -n / factory reset). */
      var url = sawDown
        ? namedAliveUrl()
        : opts.probeUrl || "/api/settings?action=status";
      fetch(url, fetchOpts)
        .then(function (r) {
          clearTimeout(to);
          if (!r.ok) throw new Error("down");
          return r.json();
        })
        .then(function (d) {
          if (done) return;
          if (sawDown && d && d.ok) {
            finish({ ok: true, alive: true, complete: d.complete });
            return;
          }
          applyStatus(d);
          if (typeof opts.onStatus === "function") opts.onStatus(d);
          if (typeof opts.isLive === "function" && opts.isLive(d)) {
            return;
          }
          if (typeof opts.shouldFinish === "function" && opts.shouldFinish(d, { sawDown: sawDown })) {
            finish(d);
          }
        })
        .catch(function () {
          clearTimeout(to);
          if (done) return;
          if (sawDown) {
            markDown();
            return;
          }
          /* H1 — a slow or 502 status CGI (e.g. during lxc-stop) is not a
             reboot. Only latch sawDown once nginx itself stops answering;
             otherwise the next /api/alive success would finish() early and
             reset.js would clear the reset markers mid-reset. */
          probeNamedAlive().then(
            function () {
              if (done) return;
              tickProgress();
            },
            function () {
              if (done) return;
              sawDown = true;
              markDown();
            }
          );
        });
    }

    function markDown() {
      if (!downSince) downSince = Date.now();
      if (activeStepper) activeStepper.tick(true);
      tickProgress();
      maybeFinishAfterDown();
    }

    if (opts.stepKind) renderStepList(opts.stepKind);
    setProgress(
      {
        title: ui.title,
        labelId: ui.labelId,
        fillId: ui.fillId,
        barId: ui.barId,
        detailId: ui.detailId
      },
      0,
      txt(opts.startingDetail) || T("wait.working"),
      false
    );
    applyHeading(ui.title, null);
    progressTimer = setInterval(function () {
      tickProgress();
      maybeFinishAfterDown();
    }, 500);
    tickProgress();

    setTimeout(function () {
      if (done) return;
      probe();
      timer = setInterval(probe, 2500);
    }, opts.probeDelayMs != null ? opts.probeDelayMs : 3000);

    setTimeout(function () {
      if (done) return;
      fetch(opts.probeUrl || "/api/settings?action=status", { cache: "no-store" })
        .then(function (r) {
          return r.json();
        })
        .then(function (d) {
          if (done) return;
          if (typeof opts.isLive === "function" && opts.isLive(d)) return;
          if (typeof opts.shouldFinish === "function" && opts.shouldFinish(d, { sawDown: true })) {
            finish(d);
          }
        })
        .catch(function () {
          /* keep polling */
        });
    }, expectedMs + 20000);

    return { finish: finish };
  }

  global.KnotsProgressWait = {
    $: $,
    setProgress: setProgress,
    readState: readState,
    writeState: writeState,
    clearState: clearState,
    runWait: runWait,
    LAN_DROP: LAN_DROP,
    lanDrop: lanDrop,
    draw: draw,
    T: T,
    showLinkDown: showLinkDown,
    watchOnline: watchOnline,
    namedAliveUrl: namedAliveUrl,
    probeNamedAlive: probeNamedAlive,
    handoffWhenReady: handoffWhenReady,
    collectHandoffProbes: collectHandoffProbes,
    showHandoffStay: showHandoffStay,
    NAMED_HOST: NAMED_HOST,
    applyStep: applyStep,
    applyStatus: applyStatus,
    renderStepList: renderStepList,
    STEP_SETS: STEP_SETS
  };
})(window);
