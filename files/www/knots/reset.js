/* SPDX-License-Identifier: GPL-2.0-only */
/* Factory reset wait page — reuses KnotsProgressWait. */
(function () {
  var PW = window.KnotsProgressWait;
  if (!PW) return;

  if (location.protocol === "https:") {
    location.replace("http://" + (window.KnotsIue ? window.KnotsIue.host() : "rnode.local") + location.pathname + location.search);
    return;
  }

  var params = new URLSearchParams(location.search || "");
  var st = PW.readState("knotsFactoryResetWait");
  var fromUi = params.get("go") === "1" || params.get("hw") === "1";
  var expected =
    Number(params.get("sec") || 0) ||
    (st && st.expectedMs / 1000) ||
    650;

  function routerHost() {
    return (window.KnotsIue ? window.KnotsIue.host() : "rnode.local");
  }

  function namedUrl(path) {
    return window.KnotsIue.destUrl(path, "nocache=" + Date.now());
  }


  function destUrl(dest) {
    var extra = "nocache=" + Date.now();
    if (dest && dest.page === "setup") {
      if (window.KnotsIue && typeof window.KnotsIue.setupStartUrl === "function") {
        return window.KnotsIue.setupStartUrl(extra);
      }
      return namedUrl("/setup.html");
    }
    if (dest && dest.path) return namedUrl(dest.path);
    return namedUrl("/setup.html");
  }

  function openWhenReady() {
    if (PW.$("waitHint")) {
      PW.$("waitHint").textContent =
        "Looking for http://" + routerHost() + " — opening Setup when it is ready…";
    }
    if (typeof PW.handoffWhenReady !== "function") {
      window.location.replace(namedUrl("/setup.html"));
      return;
    }
    PW.handoffWhenReady("reset", {
      requireDown: false,
      forceFinished: true,
      onWatchTick: function (ctx) {
        if (ctx && ctx.sawDown && PW.showLinkDown) {
          PW.showLinkDown(
            "Waiting for http://" + routerHost() + " to come back. Opening Setup."
          );
        }
      },
      onReady: function (dest) {
        window.location.replace(destUrl(dest));
      }
    });
  }

  function showResetIdle() {
    if (PW.$("waitTitle")) PW.$("waitTitle").textContent = "Factory Reset";
    PW.setProgress(
      { title: "Factory Reset" },
      0,
      "No factory reset in progress. Use Settings → Reset to factory defaults.",
      false
    );
    if (PW.$("waitHint")) {
      PW.$("waitHint").textContent =
        "This page stays here so it does not bounce you to a broken Settings or HTTPS page.";
    }
  }

  function leaveIdle(d) {
    PW.clearState("knotsFactoryResetWait");
    fetch("/api/setup?action=factory_reset_clear", {
      method: "POST",
      cache: "no-store"
    }).catch(function () {
      /* ignore */
    });
    if (d && d.complete === false) {
      openWhenReady();
      return;
    }
    showResetIdle();
  }

  function start(exp, startedAt) {
    PW.runWait({
      storageKey: "knotsFactoryResetWait",
      expectedSeconds: exp,
      startedAt: startedAt,
      title: "Factory Reset in Progress",
      stepKind: "reset",
      startingDetail: "Stopping BTC Node…",
      probeUrl: "/api/setup?action=status",
      probeDelayMs: 3000,
      finishMsAfterDown: 15000,
      onDownLinger: function () {
        if (PW.showLinkDown) {
          PW.showLinkDown(
            "Factory reset is rebooting the router."
          );
        }
      },
      isLive: function (d) {
        return !!(d && d.factory_reset_live);
      },
      shouldFinish: function (d, ctx) {
        if (!d) return false;
        /* Stay only while THIS boot still has /tmp live marker. */
        if (d.factory_reset_live) return false;
        /*
         * Finish when:
         * - Setup must run again (normal post-reset), or
         * - Reset is no longer live/active (aborted / already finished / Setup done),
         * - or we saw downtime and the appliance answered again.
         */
        if (d.complete === false) return true;
        if (!d.factory_reset_active) return true;
        if (ctx && ctx.sawDown) return true;
        return false;
      },
      onFinish: function () {
        PW.clearState("knotsFactoryResetWait");
        if (PW.$("waitHint")) {
          PW.$("waitHint").textContent = "Factory reset finished — opening Setup…";
        }
        fetch("/api/setup?action=factory_reset_clear", {
          method: "POST",
          cache: "no-store"
        })
          .catch(function () {
            /* ignore */
          })
          .then(function () {
            openWhenReady();
          });
      }
    });
  }

  fetch("/api/setup?action=status", { cache: "no-store" })
    .then(function (r) {
      return r.json();
    })
    .then(function (d) {
      if (d && d.factory_reset_expected_seconds) {
        expected = Number(d.factory_reset_expected_seconds) || expected;
      }
      var live = !!(d && d.factory_reset_live);
      var active = !!(d && d.factory_reset_active);

      /* No armed reset — never trap on this page (stale sessionStorage / ?hw=1). */
      if (!live && !active) {
        leaveIdle(d);
        return;
      }

      if (st && st.started && Date.now() - st.started < 20 * 60 * 1000) {
        start(st.expectedMs / 1000, st.started);
        return;
      }
      if (live || active || fromUi) {
        start(expected, Date.now());
        return;
      }
      leaveIdle(d);
    })
    .catch(function () {
      /* Offline during reboot — if we have wait state, keep polling. */
      if (st && st.started && Date.now() - st.started < 20 * 60 * 1000) {
        start(st.expectedMs / 1000, st.started);
      } else if (fromUi) {
        start(expected, Date.now());
      } else {
        PW.setProgress(
          { title: "Factory Reset in Progress" },
          0,
          "Waiting for the router…",
          true
        );
        start(expected, Date.now());
      }
    });
})();
