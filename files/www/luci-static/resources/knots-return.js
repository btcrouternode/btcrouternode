/* SPDX-License-Identifier: GPL-2.0-only */
/* Return link helper: login → under modal (styled); other pages → top bar.
   Authenticated "Node Dashboard" must log out of LuCI first (U1a) — use
   /cgi-bin/luci/admin/node-dashboard (action_exit), not a bare Node URL. */
(function () {
  /* D2: same host the browser used (appliance names / private IPv4), else
     rnode.local — clients without mDNS reach LuCI by IP. */
  function nodeDashboardHref() {
    return "https://" + (function () { var h = (location.hostname || "").toLowerCase(); return /^(rnode\.local|rnode-[0-9a-f]{4}\.local|node-router|knots-router)$|^(10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}$|^192\.168\.\d{1,3}\.\d{1,3}$|^172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}$/.test(h) ? h : "rnode.local"; })() + "/";
  }
  /* Server-side session destroy + redirect (see node_dashboard.uc). */
  var EXIT_HREF = "/cgi-bin/luci/admin/node-dashboard";

  /* Strings: the RNode catalogue copied here by ui-ports.sh (uhttpd has no
     /i18n/). English is built in so LuCI never waits on it; the page's
     language (LuCI sets <html lang>, same as the RNode pages) is fetched
     once and the links re-labelled. */
  var I18N_BASE = "/luci-static/resources/knots-i18n/";
  var SUPPORTED = ["en", "es", "de", "fr", "zh-cn", "ja", "pt-br"];
  var EN = {
    "luci.return.link": "\u2190 Node Dashboard",
    "luci.return.title": "Log out of router settings and open Node Status",
    "luci.return.bar": "Router settings (LuCI)"
  };
  var dict = {};
  function T(k) {
    var v = dict[k];
    return v != null && v !== "" ? v : EN[k] || k;
  }
  function langCode(c) {
    c = String(c || "").toLowerCase().replace(/_/g, "-");
    if (!c || c === "auto") return "";
    if (c.indexOf("zh") === 0) return "zh-cn";
    if (c.indexOf("pt") === 0) return "pt-br";
    c = c.split("-")[0];
    return SUPPORTED.indexOf(c) >= 0 ? c : "";
  }
  function loadLang() {
    var code =
      langCode(document.documentElement && document.documentElement.getAttribute("lang")) ||
      langCode(navigator.language) ||
      "en";
    if (code === "en" || !window.fetch) return;
    fetch(I18N_BASE + code + ".json")
      .then(function (r) {
        if (!r.ok) throw new Error("http " + r.status);
        return r.json();
      })
      .then(function (d) {
        dict = d || {};
        relabel();
      })
      .catch(function () {
        /* English stays */
      });
  }
  function relabel() {
    var a = document.querySelector("#" + LOGIN_ID + " a");
    if (a) a.textContent = T("luci.return.link");
    var bar = document.getElementById(BAR_ID);
    if (bar) {
      var link = bar.querySelector("a");
      if (link) {
        link.textContent = T("luci.return.link");
        link.title = T("luci.return.title");
      }
      var span = bar.querySelector("span");
      if (span) span.textContent = T("luci.return.bar");
    }
  }
  var LOGIN_ID = "knots-login-return";
  var BAR_ID = "knots-return-bar";

  function ensureLoginStyle() {
    if (document.getElementById("knots-login-return-style")) return;
    var st = document.createElement("style");
    st.id = "knots-login-return-style";
    st.type = "text/css";
    st.textContent =
      "#modal_overlay>#knots-login-return{display:block!important;box-sizing:border-box!important;text-align:center!important;margin:12px auto 40px!important;padding:0!important;z-index:901!important}" +
      "#modal_overlay>#knots-login-return a{display:block!important;width:100%!important;text-align:center!important;color:#ffe8c4!important;font-family:\"Helvetica Neue\",Helvetica,Arial,sans-serif!important;font-size:16px!important;font-weight:700!important;line-height:36px!important;text-decoration:underline!important}";
    (document.head || document.documentElement).appendChild(st);
  }

  function placeLogin() {
    var modal = document.querySelector("#modal_overlay > .modal.login");
    if (!modal || !modal.parentNode) return false;
    ensureLoginStyle();
    var top = document.getElementById(BAR_ID);
    if (top) top.parentNode.removeChild(top);
    var el = document.getElementById(LOGIN_ID);
    if (!el) {
      el = document.createElement("div");
      el.id = LOGIN_ID;
      el.setAttribute("role", "navigation");
      var a = document.createElement("a");
      /* Not logged in yet — go straight to Node UI */
      a.href = nodeDashboardHref();
      a.textContent = T("luci.return.link");
      el.appendChild(a);
      modal.parentNode.insertBefore(el, modal.nextSibling);
    }
    var w = modal.offsetWidth || 0;
    if (w > 0) {
      el.style.width = w + "px";
      el.style.maxWidth = w + "px";
    }
    return true;
  }

  function placeBar() {
    if (document.querySelector("#modal_overlay > .modal.login")) return;
    if (document.getElementById(BAR_ID) || document.getElementById(LOGIN_ID)) return;
    if (!document.body) return;
    var bar = document.createElement("div");
    bar.id = BAR_ID;
    bar.setAttribute("role", "navigation");
    var link = document.createElement("a");
    link.href = EXIT_HREF;
    link.title = T("luci.return.title");
    link.textContent = T("luci.return.link");
    var span = document.createElement("span");
    span.textContent = T("luci.return.bar");
    bar.appendChild(link);
    bar.appendChild(span);
    document.body.insertBefore(bar, document.body.firstChild);
  }

  function paint() {
    if (placeLogin()) return;
    placeBar();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", paint);
  } else {
    paint();
  }
  loadLang();
  setInterval(paint, 500);
})();
