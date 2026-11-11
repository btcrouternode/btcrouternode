/* SPDX-License-Identifier: GPL-2.0-only */
/* Firmware upgrade wait page — reuses KnotsProgressWait. */
(function () {
  var PW = window.KnotsProgressWait;
  if (!PW) return;

  function T(k, v) { return window.KnotsI18n ? window.KnotsI18n.t(k, v) : k; }
  /* Text drawn once is drawn again when the language loads (progress-wait). */
  function draw(id, fn) {
    if (PW.draw) {
      PW.draw(id, fn);
      return;
    }
    var el = PW.$(id);
    if (el) fn(el);
  }
  function lanDrop() {
    return PW.lanDrop ? PW.lanDrop() : PW.LAN_DROP || "";
  }

  /* HTTPS cannot poll http://rnode.local (mixed content) and after -n the
     new CA makes same-origin HTTPS probes fail. Stay on HTTP. */
  if (location.protocol === "https:") {
    location.replace("http://" + (window.KnotsIue ? window.KnotsIue.host() : "rnode.local") + location.pathname + location.search);
    return;
  }

  /* Functions: read in the current language each time the page redraws. */
  function UPGRADE_TITLE() { return T("upgrade.title"); }
  function REBOOT_TITLE() { return T("upgrade.reboot_title"); }
  function REBOOT_DETAIL() { return T("upgrade.reboot_detail"); }

  var params = new URLSearchParams(location.search || "");
  var st = PW.readState("knotsUpgradeWait");
  var prev =
    params.get("prev") ||
    (st && st.prev) ||
    "";
  function resolveKeepConfig(setupStatus, settingsStatus) {
    var keepParam = params.get("keep");
    if (keepParam === "0" || keepParam === "false") return false;
    if (keepParam === "1" || keepParam === "true") return true;
    if (st && (st.keepConfig === false || st.keepConfig === 0 || st.keepConfig === "0")) {
      return false;
    }
    if (st && (st.keepConfig === true || st.keepConfig === 1 || st.keepConfig === "1")) {
      return true;
    }
    /* Server marker while upgrade is armed this boot. */
    if (setupStatus && setupStatus.upgrade_keep_config === false) return false;
    if (settingsStatus && settingsStatus.upgrade_keep_config === false) return false;
    /* Post -n sysupgrade: Setup must run — only when an upgrade session exists. */
    if (
      st &&
      setupStatus &&
      setupStatus.complete === false &&
      !setupStatus.upgrade_live
    ) {
      return false;
    }
    return true;
  }

  var keepConfig = true;
  var fromUi = params.get("go") === "1";
  var expected =
    Number(params.get("sec") || 0) ||
    (st && st.expectedMs / 1000) ||
    300;


  /* Host per D2 (shell.js KnotsIue.host).
     Reset-settings (-n) opens IUE at Welcome (step 0), not a mid-wizard resume. */
  function destAbsolute(path) {
    return window.KnotsIue.destUrl(path, "nocache=" + Date.now());
  }


  function destUrl(dest) {
    var extra = "nocache=" + Date.now();
    if (!dest) return destAbsolute("/");
    if (dest.page === "setup" || (dest.path && dest.path.indexOf("/setup.html") === 0)) {
      if (window.KnotsIue && typeof window.KnotsIue.setupStartUrl === "function") {
        return window.KnotsIue.setupStartUrl(extra);
      }
      return destAbsolute("/setup.html");
    }
    return destAbsolute(dest.path || "/");
  }

  /* Alive is not enough — open dest only when that page itself works. */
  function redirectWhenReady(kind, extra) {
    extra = extra || {};
    draw("waitHint", function (el) {
      el.textContent = T("upgrade.looking", {
        url: "http://" + (window.KnotsIue ? window.KnotsIue.host() : "rnode.local")
      });
    });
    if (typeof PW.handoffWhenReady !== "function") {
      return;
    }
    PW.handoffWhenReady(kind, {
      requireDown: extra.requireDown === true,
      forceFinished: extra.forceFinished !== false,
      prevVersion: extra.prevVersion || prev,
      startedAt: extra.startedAt,
      expectedMs: extra.expectedMs,
      onWatchTick: function (ctx) {
        if (ctx && ctx.sawDown && PW.showLinkDown) {
          PW.showLinkDown(function () {
            return T("upgrade.waiting_back", {
              url: "http://" + (window.KnotsIue ? window.KnotsIue.host() : "rnode.local")
            });
          });
        }
      },
      onReady: function (dest) {
        window.location.replace(destUrl(dest));
      }
    });
  }

  function applyKeepCopy() {
    /* Our own catalogue strings (simple <strong> markup only). */
    draw("waitCopy", function (copy) {
      copy.innerHTML = keepConfig ? T("upgrade.copy_keep") : T("upgrade.copy_reset");
    });
    draw("waitHint", function (hint) {
      hint.textContent =
        (keepConfig ? T("upgrade.hint_keep") : T("upgrade.hint_reset")) +
        " " + lanDrop();
    });
  }

  function clearUpgradeUi() {
    fetch("/api/setup?action=upgrade_clear", {
      method: "POST",
      cache: "no-store"
    }).catch(function () {
      /* ignore */
    });
  }

  /*
   * U13 failure path — when sysupgrade fails WITHOUT rebooting, the backend
   * writes {"phase":"failed","detail":…} to /tmp/knots/upgrade-status.json,
   * exposed as the "upgrade" field of /api/settings?action=status.
   */
  function failedPhase(d) {
    return d && d.upgrade && d.upgrade.phase === "failed" ? d.upgrade : null;
  }

  /* Show the failed message + way back instead of waiting forever. */
  function showUpgradeFailed(upg) {
    /* upg.detail comes from the router (not translated). */
    function detail() {
      return (upg && upg.detail) || T("upgrade.failed_detail");
    }
    draw("waitTitle", function (el) {
      el.textContent = T("upgrade.failed_title");
    });
    draw("waitWarn", function (el) {
      el.textContent = T("upgrade.failed_warn");
    });
    PW.setProgress(
      { title: T("upgrade.failed_title"), labelId: "waitProgressLabel" },
      100,
      detail(),
      false
    );
    draw("waitHint", function (hint) {
      hint.textContent = detail() + " ";
      var a = document.createElement("a");
      a.href = destAbsolute("/settings.html");
      a.textContent = T("upgrade.return_settings");
      hint.appendChild(a);
      hint.appendChild(document.createTextNode("."));
    });
  }

  function finishKind(setupStatus) {
    if (!keepConfig) return "upgrade";
    if (setupStatus && setupStatus.complete === false) return "upgrade";
    return "upgradeKeep";
  }

  function leaveIdle(setupStatus) {
    PW.clearState("knotsUpgradeWait");
    clearUpgradeUi();
    var kind = finishKind(setupStatus);
    redirectWhenReady(kind, {
      forceFinished: true,
      requireDown: false,
      startedAt: st && st.started,
      expectedMs: (st && st.expectedMs) || expected * 1000
    });
  }

  function start(exp, startedAt, prevVer) {
    applyKeepCopy();
    var probeUrl = keepConfig
      ? "/api/settings?action=status"
      : "/api/setup?action=status";
    var wait = PW.runWait({
      storageKey: "knotsUpgradeWait",
      expectedSeconds: exp,
      startedAt: startedAt,
      prev: prevVer || "",
      keepConfig: keepConfig,
      title: UPGRADE_TITLE,
      stepKind: keepConfig ? "upgradeKeep" : "upgrade",
      rebootTitle: REBOOT_TITLE,
      rebootDetail: REBOOT_DETAIL,
      finishingDetail: function () { return T("upgrade.finishing"); },
      headingId: "waitTitle",
      warnId: "waitWarn",
      startingDetail: function () {
        return keepConfig ? T("upgrade.starting_keep") : T("upgrade.starting_reset");
      },
      probeUrl: probeUrl,
      probeDelayMs: 5000,
      /* After this much downtime, keep this page and explain the LAN drop. */
      finishMsAfterDown: keepConfig ? 15000 : 45000,
      onDownLinger: function () {
        if (PW.showLinkDown) PW.showLinkDown(REBOOT_DETAIL);
      },
      isLive: function (d) {
        return !!(d && d.upgrade_live);
      },
      shouldFinish: function (d, ctx) {
        if (!d) return false;
        if (d.upgrade_live) return false;
        if (!d.ok) return false;
        /* U13 — sysupgrade failed without rebooting: stop waiting, show it. */
        if (failedPhase(d)) return true;
        /* Reset-settings (-n): Setup must run — same signal as factory reset. */
        if (!keepConfig && d.complete === false) return true;
        var ver = d.product_version || "";
        if (prevVer && ver && ver !== prevVer) return true;
        if (ctx && ctx.sawDown) return true;
        return false;
      },
      onFinish: function (d) {
        /* H6: the stall watch must stop once the wait is over. */
        if (stallTimer) clearInterval(stallTimer);
        PW.clearState("knotsUpgradeWait");
        clearUpgradeUi();
        var failed = failedPhase(d);
        if (failed) {
          showUpgradeFailed(failed);
          return;
        }
        /* destKey: wait.dest.setup / wait.dest.status */
        function openDest(kind, destKey, ver) {
          draw("waitHint", function (el) {
            el.textContent = ver
              ? T("upgrade.done_opening", { version: ver, dest: T(destKey) })
              : T("upgrade.opening", { dest: T(destKey) });
          });
          PW.setProgress(
            { title: UPGRADE_TITLE(), labelId: "waitProgressLabel" },
            100,
            T("upgrade.opening", { dest: T(destKey) }),
            false
          );
          if (PW.$("waitTitle")) PW.$("waitTitle").textContent = UPGRADE_TITLE();
          redirectWhenReady(kind, {
            forceFinished: true,
            requireDown: false,
            prevVersion: prevVer,
            startedAt: startedAt,
            expectedMs: (Number(exp) || 0) * 1000
          });
        }
        if (!keepConfig) {
          openDest("upgrade", "wait.dest.setup", "");
          return;
        }
        var ver = (d && d.product_version) || prevVer || "";
        openDest("upgradeKeep", "wait.dest.status", ver);
      }
    });

    /*
     * Stall watch. The settings status API carries BOTH upgrade_live and the
     * U13 phase object (the setup API probed on the -n path has no phase
     * field), so poll it here:
     * - failed phase + not live → sysupgrade died without rebooting: stop
     *   waiting and show the failure;
     * - F125 — still live after 3 min → sysupgrade never started: retry the
     *   apply worker once.
     */
    var resumeSent = false;
    var stallTimer = setInterval(function () {
      fetch("/api/settings?action=status", { cache: "no-store" })
        .then(function (r) {
          return r.json();
        })
        .then(function (d) {
          if (!d) return;
          if (!d.upgrade_live && failedPhase(d)) {
            clearInterval(stallTimer);
            if (wait && wait.finish) wait.finish(d);
            return;
          }
          var stallMs = Math.max(180000, (Number(expected) || 300) * 1000);
          if (resumeSent || Date.now() - startedAt < stallMs) return;
          if (!d.upgrade_live) return;
          var step = d.progress_step || "";
          if (step && step !== "none" && step !== "stop_node") return;
          resumeSent = true;
          fetch("/api/setup?action=upgrade_resume", {
            method: "POST",
            cache: "no-store"
          }).catch(function () {
            /* ignore */
          });
          draw("waitHint", function (el) {
            el.textContent = T("upgrade.stalled");
          });
        })
        .catch(function () {
          /* offline */
        });
    }, 30000);
  }

  function loadSetupStatus() {
    return fetch("/api/setup?action=status", { cache: "no-store" })
      .then(function (r) {
        return r.json();
      })
      .catch(function () {
        return null;
      });
  }

  applyKeepCopy();

  Promise.all([
    fetch("/api/settings?action=status", { cache: "no-store" })
      .then(function (r) {
        return r.json();
      })
      .catch(function () {
        return null;
      }),
    loadSetupStatus()
  ]).then(function (results) {
    var d = results[0];
    var setupStatus = results[1];
    keepConfig = resolveKeepConfig(setupStatus, d);
    applyKeepCopy();
    var live = !!(
      (d && d.upgrade_live) ||
      (setupStatus && setupStatus.upgrade_live)
    );

    if (d && d.upgrade_expected_seconds) {
      expected = Number(d.upgrade_expected_seconds) || expected;
    }
    if (setupStatus && setupStatus.upgrade_expected_seconds) {
      expected = Number(setupStatus.upgrade_expected_seconds) || expected;
    }
    if (!prev && d && d.product_version) prev = d.product_version;

    /* U13 — a sysupgrade failed without rebooting this boot: say so. */
    var failed = !live && (failedPhase(d) || failedPhase(setupStatus));
    if (failed) {
      PW.clearState("knotsUpgradeWait");
      showUpgradeFailed(failed);
      return;
    }

    if (!d && !setupStatus) {
      /* Router LAN is down (reboot / Ubuntu carrier drop). Stay here. */
      if (st && st.started) {
        start(st.expectedMs / 1000, st.started, st.prev || prev);
      } else {
        start(expected, Date.now(), prev);
      }
      return;
    }

    if (st && st.started && Date.now() - st.started < 45 * 60 * 1000) {
      var elapsed = Date.now() - st.started;
      if (!live && elapsed > 3000) {
        /* Post-reboot: marker gone — open Setup or Settings (skip arming race). */
        leaveIdle(setupStatus);
        return;
      }
      start(st.expectedMs / 1000, st.started, st.prev || prev);
      return;
    }

    if (live) {
      start(expected, Date.now(), prev);
      return;
    }

    if (fromUi && st && live) {
      start(expected, Date.now(), prev);
      return;
    }

    if (fromUi || st) {
      leaveIdle(setupStatus);
      return;
    }

    PW.setProgress(
      { title: UPGRADE_TITLE(), labelId: "waitProgressLabel" },
      0,
      T("upgrade.idle"),
      false
    );
  }).catch(function () {
    /* Offline during reboot — keep this progress page (F150). */
    keepConfig = resolveKeepConfig(null, null);
    applyKeepCopy();
    if (st && st.started) {
      start(st.expectedMs / 1000, st.started, st.prev || prev);
      return;
    }
    start(expected, Date.now(), prev);
  });
})();
