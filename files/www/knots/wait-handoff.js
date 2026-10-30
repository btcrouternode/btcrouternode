/* SPDX-License-Identifier: GPL-2.0-only */
/* Post-update / post-reset destination contract (U13, U17, N3, N13).
 * The wait tab stays on HTTP. Do not navigate until the destination page
 * itself works. Host tests require() this file. */
(function (root) {
  /* D2: host per shell.js KnotsIue.host (rnode.local without a browser). */
  function host() {
    return root && root.KnotsIue && root.KnotsIue.host ? root.KnotsIue.host() : "rnode.local";
  }
  var HOST = host();

  function decideDest(kind, probes) {
    probes = probes || {};
    if (probes.upgradeLive || probes.factoryResetLive) {
      return {
        page: "wait",
        label: "wait",
        protocol: "http",
        path: "",
        url: "",
        readyNeed: "",
        reason: "still_live"
      };
    }
    var resetKind = kind === "upgrade" || kind === "reset";
    if (resetKind || probes.setupComplete === false) {
      return {
        page: "setup",
        label: "Setup",
        protocol: "http",
        path: "/setup.html",
        url: "http://" + host() + "/setup.html?step=0",
        readyNeed: "setup_http",
        reason: "need_setup_ready"
      };
    }
    return {
      page: "status",
      label: "Node Status",
      protocol: "https",
      path: "/",
      url: "https://" + host() + "/",
      readyNeed: "status_https",
      reason: "need_status_https"
    };
  }

  function applyFinished(probes) {
    return !!(
      probes.sawReboot ||
      probes.versionChanged ||
      probes.applyElapsedOk ||
      probes.forceFinished
    );
  }

  function canNavigate(dest, probes) {
    dest = dest || {};
    probes = probes || {};
    if (!dest.url) return false;
    if (probes.upgradeLive || probes.factoryResetLive) return false;
    if (probes.alive !== true) return false;
    if (dest.readyNeed === "setup_http") {
      return probes.setupComplete === false && probes.setupPageHttp === true;
    }
    if (dest.readyNeed === "status_https") {
      return (
        probes.setupComplete === true &&
        probes.statusHttps === true &&
        applyFinished(probes)
      );
    }
    return false;
  }

  function blockedReason(dest, probes) {
    dest = dest || {};
    probes = probes || {};
    if (probes.upgradeLive || probes.factoryResetLive) return "still_live";
    if (probes.alive !== true) return "not_alive";
    if (dest.readyNeed === "setup_http") {
      if (probes.setupComplete !== false) return "setup_not_incomplete";
      if (probes.setupPageHttp !== true) return "setup_page_not_http";
      return "";
    }
    if (dest.readyNeed === "status_https") {
      if (!applyFinished(probes)) return "apply_not_finished";
      if (probes.setupComplete !== true) return "setup_not_complete";
      if (probes.statusHttps !== true) {
        return probes.statusHttp === true ? "https_untrusted" : "status_not_ready";
      }
      return "";
    }
    return "unknown";
  }

  var api = {
    HOST: HOST,
    decideDest: decideDest,
    canNavigate: canNavigate,
    blockedReason: blockedReason
  };

  root.KnotsWaitHandoff = api;
  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
})(
  typeof window !== "undefined"
    ? window
    : typeof globalThis !== "undefined"
      ? globalThis
      : this
);
