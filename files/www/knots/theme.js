/* SPDX-License-Identifier: GPL-2.0-only */
/* Node Dashboard theme: default follows desktop (prefers-color-scheme). U1b */
(function () {
  var KEY = "knots-ui-theme";
  var MODES = ["system", "light", "dark"];

  function systemDark() {
    try {
      return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
    } catch (e) {
      return false;
    }
  }

  function readPref() {
    try {
      var v = localStorage.getItem(KEY);
      if (v === "light" || v === "dark" || v === "system") return v;
    } catch (e) {}
    return "system";
  }

  function effective(pref) {
    if (pref === "light" || pref === "dark") return pref;
    return systemDark() ? "dark" : "light";
  }

  function apply(pref) {
    var mode = pref || readPref();
    var resolved = effective(mode);
    document.documentElement.setAttribute("data-theme", resolved);
    document.documentElement.setAttribute("data-theme-pref", mode);
    try {
      localStorage.setItem(KEY, mode);
    } catch (e) {}
    return { pref: mode, theme: resolved };
  }

  function setPref(mode) {
    if (MODES.indexOf(mode) < 0) mode = "system";
    var r = apply(mode);
    try {
      window.dispatchEvent(new CustomEvent("knots-theme", { detail: r }));
    } catch (e) {}
    return r;
  }

  // Apply before first paint when loaded in <head>
  apply(readPref());

  var mq;
  try {
    mq = window.matchMedia("(prefers-color-scheme: dark)");
    var onChange = function () {
      if (readPref() === "system") apply("system");
    };
    if (mq.addEventListener) mq.addEventListener("change", onChange);
    else if (mq.addListener) mq.addListener(onChange);
  } catch (e) {}

  window.KnotsTheme = {
    key: KEY,
    modes: MODES,
    read: readPref,
    apply: apply,
    set: setPref,
    effective: function () {
      return effective(readPref());
    }
  };
})();
