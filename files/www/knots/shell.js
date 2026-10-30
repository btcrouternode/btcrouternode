/* SPDX-License-Identifier: GPL-2.0-only */
/* Shared segmented top nav under brand header + theme icons.
   Brand title follows active impl (U10): Bitcoin Knots or Bitcoin Core. */
(function () {
  /* D4 (review 2026-10-10): the wait-page service worker is retired — the
     wait pages are plain HTTP by design, where browsers never run service
     workers, and on HTTPS its scope "/" cached Node/Settings pages too.
     Drop any registration a browser still holds (wait-sw.js is now a
     self-unregistering stub for clients that never load this page again). */
  if (typeof navigator !== "undefined" && navigator.serviceWorker &&
      navigator.serviceWorker.getRegistrations) {
    navigator.serviceWorker.getRegistrations().then(function (regs) {
      regs.forEach(function (r) {
        r.unregister();
      });
    }).catch(function () {});
  }

  /* Phase 2 (U9/U12): Node Status + Node software + Settings (+ LuCI).
     Wallet/External/Lightning/Privacy return in Phase 3. */
  var items = [
    { href: "/", label: "Node Status", i18n: "nav.status", match: /^\/$|^\/index\.html$/ },
    { href: "/node.html", label: "Node software", i18n: "nav.node", match: /node\.html$/ },
    { href: "/settings.html", label: "Settings", i18n: "nav.settings", match: /settings\.html$/ }
    /* U8/S7 — no M.2 wipe surface (nav, page, API, or CLI). */
  ];
  /* Host for every browser link (LuCI :8443 / Node :443 / wait pages).
     D2 (review 2026-10-11): keep the name the user actually reached us by —
     rnode.local where mDNS works, the router's DNS names, or the LAN IP on
     clients without mDNS (DoH, VPN, some Android/Windows setups). All of
     these are in the leaf certificate (SANs). Anything else (an unexpected
     name) falls back to rnode.local. followLanIp() moves an IP host when the LAN IP
     is about to change (Setup cutover). */
  var hostOverride = "";
  function hostIsAppliance(h) {
    h = String(h || "").toLowerCase();
    if (h === "rnode.local" || h === "node-router" || h === "knots-router") return true;
    if (/^rnode-[0-9a-f]{4}\.local$/.test(h)) return true; /* N20 unit name */
    return /^(10|127)\.\d{1,3}\.\d{1,3}\.\d{1,3}$|^192\.168\.\d{1,3}\.\d{1,3}$|^172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}$/.test(h);
  }
  function applianceHost() {
    if (hostOverride) return hostOverride;
    var h = typeof location !== "undefined" ? location.hostname : "";
    return hostIsAppliance(h) ? h.toLowerCase() : "rnode.local";
  }
  /* An IP host follows a LAN move; a name (rnode.local …) stays. */
  function followLanIp(newIp) {
    var h = applianceHost();
    if (newIp && /^\d/.test(h) && hostIsAppliance(newIp)) hostOverride = newIp;
  }
  function luciUrl() {
    return "https://" + applianceHost() + ":8443/cgi-bin/luci/";
  }

  function onNodeSoftwarePage() {
    return /node\.html$/.test(path());
  }

  function brandLabel(impl) {
    if (impl === "core") return "Bitcoin Core";
    if (impl === "knots") return "Bitcoin Knots";
    /* Setup IUE before node choice */
    return "Bitcoin Node";
  }

  function applyBrand(impl) {
    var name = brandLabel(impl);
    var h1 = document.querySelector(".brand h1");
    var eyebrow = document.querySelector(".brand .eyebrow");
    /* U11 Node software: keep product brand; show active impl as running state */
    if (onNodeSoftwarePage()) {
      if (h1) {
        h1.textContent =
          name === "Bitcoin Node"
            ? "Bitcoin Node"
            : "Bitcoin Node - Running " + name;
      }
      if (document.title) {
        document.title = "Node software — Bitcoin Node";
      }
      return;
    }
    if (h1) h1.textContent = name;
    if (eyebrow && /Bitcoin (Knots|Core|Node)/i.test(eyebrow.textContent || "")) {
      eyebrow.textContent = name;
    }
    if (document.title) {
      document.title = document.title.replace(/Bitcoin (Knots|Core|Node)/gi, name);
    }
  }

  /* R1a — always-visible appliance build for SD/board troubleshooting */
  function applyBuild(productVer, buildNum) {
    var el = document.getElementById("applianceBuild");
    if (!el) return;
    var ver = (productVer || "").trim();
    var bn = (buildNum || "").trim();
    if (!ver || ver === "unknown") {
      el.textContent = "Appliance build: unknown";
      el.title = "Product version not found under /etc/knots/product_version";
      return;
    }
    var text = "Appliance build " + ver;
    if (bn && bn !== "unknown" && ver.indexOf("." + bn) === -1) {
      text += " (rev " + bn + ")";
    } else if (bn && bn !== "unknown") {
      text += " · rev " + bn;
    }
    el.textContent = text;
    el.title =
      "R1a product version {openwrt}.{knots}.{build} — identify this SD/eMMC image when filing bugs";
  }

  function ensureBuildStrip(afterEl) {
    if (document.getElementById("applianceBuild")) return;
    var p = document.createElement("p");
    p.id = "applianceBuild";
    p.className = "appliance-build";
    p.setAttribute("aria-label", "Appliance build version");
    p.textContent = "Appliance build: …";
    afterEl.insertAdjacentElement("afterend", p);
  }

  function refreshBrand() {
    return fetch("/api/status", { cache: "no-store" })
      .then(function (r) {
        return r.json();
      })
      .then(function (d) {
        applyBrand(d && d.node_impl);
        applyBuild(d && d.product_version, d && d.build_number);
      })
      .catch(function () {
        /* keep static HTML default */
      });
  }

  window.KnotsBrand = {
    apply: applyBrand,
    applyBuild: applyBuild,
    refresh: refreshBrand,
    label: brandLabel
  };

  var ICON_SUN =
    '<svg class="theme-icon" viewBox="0 0 24 24" aria-hidden="true">' +
    '<circle cx="12" cy="12" r="4" fill="currentColor"/>' +
    '<g stroke="currentColor" stroke-width="2" stroke-linecap="round">' +
    '<path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>' +
    "</g></svg>";

  var ICON_MOON =
    '<svg class="theme-icon" viewBox="0 0 24 24" aria-hidden="true">' +
    '<path fill="currentColor" d="M21 14.3A9 9 0 0 1 9.7 3 7.5 7.5 0 1 0 21 14.3z"/>' +
    "</svg>";

  function path() {
    return location.pathname || "/";
  }

  function onSetupPage() {
    return /setup\.html$/.test(path());
  }

  function onResetPage() {
    return /reset\.html$/.test(path());
  }

  function onUpgradePage() {
    return /upgrade\.html$/.test(path());
  }

  function onTlsHelpPage() {
    return /tls\.html$/.test(path());
  }

  function tlsStepDone() {
    return /after_tls=1/.test(location.search || "");
  }

  /* U17 / N13 — Setup entry on HTTP until HTTPS trust step succeeds */
  function setupPageUrl(query) {
    var h = applianceHost();
    var q = query || "";
    if (q && q.charAt(0) !== "?") q = "?" + q;
    return "http://" + h + "/setup.html" + q;
  }

  function clearTlsResumeFlags() {
    try {
      sessionStorage.removeItem("knots_tls_continue");
      sessionStorage.removeItem("knots_tls_reloaded");
    } catch (e) {}
  }

  /* Factory reset / sysupgrade -n: Welcome (step 0), not a leftover TLS resume. */
  function setupStartUrl(query) {
    clearTlsResumeFlags();
    var extra = query || "";
    if (extra && extra.charAt(0) === "?") extra = extra.slice(1);
    extra = extra
      .replace(/(?:^|&)step=\d+\b/g, "")
      .replace(/^&+|&+$/g, "");
    var q = "step=0";
    if (extra) q += "&" + extra;
    return setupPageUrl(q);
  }

  function iuePageUrl(pagePath, query) {
    var h = applianceHost();
    var q = query || "";
    if (q && q.charAt(0) !== "?") q = "?" + q;
    if (tlsStepDone() || /after_tls=1/.test(q)) {
      return "https://" + h + pagePath + q;
    }
    return "http://" + h + pagePath + q;
  }

  /* Wait pages must stay on HTTP so the post-reboot monitor can poll
     http://<host>/api/alive (HTTPS is a new CA after -n / reset). */
  function waitPageUrl(path, query) {
    var q = query || "";
    if (q && q.charAt(0) !== "?") q = "?" + q;
    return "http://" + applianceHost() + path + q;
  }

  /* Wait pages always HTTP. HTTPS Setup stays — bouncing it to HTTP Welcome
     restarted IUE after the CA was installed (F208). */
  function ensureCleartextIue() {
    if (location.protocol !== "https:") return;
    if (onResetPage() || onUpgradePage()) {
      location.replace(
        "http://" + applianceHost() + location.pathname + location.search
      );
    }
  }

  /* Absolute https://<host>/… (or http Setup / wait pages) — host per D2. */
  function applianceUrl(path, query) {
    var q = query || "";
    if (q && q.charAt(0) !== "?") q = "?" + q;
    if (!path) path = "/";
    if (path.charAt(0) !== "/") path = "/" + path;
    if (path.indexOf("/setup.html") === 0) return setupPageUrl(q);
    if (path.indexOf("/upgrade.html") === 0 || path.indexOf("/reset.html") === 0) {
      return waitPageUrl(path, q);
    }
    return "https://" + applianceHost() + path + q;
  }

  /* H7 (review 2026-10-11): the ONE "where to go next" builder. Setup opens
     at Welcome (step 0); upgrade/reset wait pages stay on HTTP; everything
     else is HTTPS on the D2 host. reset.js / upgrade.js / settings.js used to
     each carry a copy with its own hard-coded fallback host. */
  function destUrl(path, query) {
    if (!path) path = "/";
    if (path.indexOf("/setup.html") === 0) return setupStartUrl(query);
    return applianceUrl(path, query);
  }

  window.KnotsIue = {
    destUrl: destUrl,
    host: applianceHost,
    hostIsAppliance: hostIsAppliance,
    followLanIp: followLanIp,
    setupUrl: setupPageUrl,
    setupStartUrl: setupStartUrl,
    waitUrl: waitPageUrl,
    pageUrl: iuePageUrl,
    appUrl: applianceUrl,
    ensureCleartext: ensureCleartextIue
  };

  /* U17 — reset page wins over Setup; else redirect until /etc/knots/setup-complete */
  function gateSetup() {
    if (onSetupPage() || onTlsHelpPage() || onResetPage() || onUpgradePage()) return;
    var ac = typeof AbortController !== "undefined" ? new AbortController() : null;
    var to = setTimeout(function () {
      if (ac) ac.abort();
    }, 2500);
    var opts = { cache: "no-store" };
    if (ac) opts.signal = ac.signal;
    fetch("/api/setup?action=status", opts)
      .then(function (r) {
        return r.json();
      })
      .then(function (d) {
        if (d && d.upgrade_live && d.complete !== false) {
          location.replace(applianceUrl("/upgrade.html", "go=1&nocache=" + Date.now()));
          return;
        }
        if (d && d.factory_reset_live && d.complete !== false) {
          location.replace(applianceUrl("/reset.html", "hw=1&nocache=" + Date.now()));
          return;
        }
        if (d && d.complete === false) {
          /* HTTPS mid-IUE means the CA is already trusted — resume at Choice,
             not HTTP Welcome (after_tls). HTTP still starts at Welcome. */
          if (location.protocol === "https:") {
            location.replace(
              "https://" + applianceHost() + "/setup.html?after_tls=1"
            );
            return;
          }
          location.replace(setupStartUrl());
        }
      })
      .catch(function () {
        /* API missing / timed out — do not block Node Status */
      })
      .then(function () {
        clearTimeout(to);
      });
  }

  /* WPS / Settings: open tabs must jump to upgrade or reset progress pages
     (upgrade first). H6/H7 (review 2026-10-11): the ONE poller for this —
     reset-watch.js duplicated it — and it pauses while the tab is hidden
     instead of hitting the CGI every 2 s forever; a tab that becomes visible
     checks at once. */
  function watchFactoryReset() {
    if (onResetPage() || onUpgradePage()) return;
    if (onSetupPage() || onTlsHelpPage()) return;
    var timer = null;
    var busy = false;
    function tick() {
      if (busy || (typeof document !== "undefined" && document.hidden)) return;
      busy = true;
      fetch("/api/settings?action=status", { cache: "no-store" })
        .then(function (r) {
          if (!r.ok) throw new Error("http");
          return r.json();
        })
        .then(function (d) {
          if (d && d.upgrade_live) {
            location.replace(applianceUrl("/upgrade.html", "go=1&nocache=" + Date.now()));
            return;
          }
          if (d && d.factory_reset_live) {
            location.replace(applianceUrl("/reset.html", "hw=1&nocache=" + Date.now()));
          }
        })
        .catch(function () {
          /* offline during reboot — ignore */
        })
        .then(function () {
          busy = false;
        });
    }
    tick();
    timer = setInterval(tick, 3000);
    if (typeof document !== "undefined" && document.addEventListener) {
      document.addEventListener("visibilitychange", function () {
        if (!document.hidden) tick();
      });
    }
    return timer;
  }

  function syncThemeButtons(root) {
    if (!root || !window.KnotsTheme) return;
    var pref = window.KnotsTheme.read();
    var buttons = root.querySelectorAll("button[data-theme-set]");
    for (var i = 0; i < buttons.length; i++) {
      var b = buttons[i];
      var on = b.getAttribute("data-theme-set") === pref;
      b.setAttribute("aria-pressed", on ? "true" : "false");
    }
  }

  function themeToggle() {
    var wrap = document.createElement("div");
    wrap.id = "theme-toggle";
    wrap.className = "theme-toggle";
    wrap.setAttribute("role", "group");
    wrap.setAttribute("aria-label", "Colour theme");

    var modes = [
      {
        id: "system",
        title: "Auto — match desktop light/dark",
        html: '<span class="theme-auto" aria-hidden="true">A</span>'
      },
      { id: "light", title: "Light theme", html: ICON_SUN },
      { id: "dark", title: "Dark theme", html: ICON_MOON }
    ];
    for (var i = 0; i < modes.length; i++) {
      (function (m) {
        var btn = document.createElement("button");
        btn.type = "button";
        btn.setAttribute("data-theme-set", m.id);
        btn.setAttribute("aria-label", m.title);
        btn.title = m.title;
        btn.innerHTML = m.html;
        btn.addEventListener("click", function () {
          if (window.KnotsTheme) window.KnotsTheme.set(m.id);
          syncThemeButtons(wrap);
        });
        wrap.appendChild(btn);
      })(modes[i]);
    }
    syncThemeButtons(wrap);
    window.addEventListener("knots-theme", function () {
      syncThemeButtons(wrap);
    });
    return wrap;
  }

  function placeThemeInBrand(brand) {
    if (document.getElementById("theme-toggle")) return;
    var eyebrow = brand.querySelector(".eyebrow");
    var h1 = brand.querySelector("h1");
    var tagline = brand.querySelector(".tagline");
    if (!h1) {
      brand.appendChild(themeToggle());
      return;
    }

    var bar = document.createElement("div");
    bar.className = "brand-bar";
    var text = document.createElement("div");
    text.className = "brand-text";
    if (eyebrow) text.appendChild(eyebrow);
    text.appendChild(h1);
    bar.appendChild(text);
    bar.appendChild(themeToggle());

    if (tagline) brand.insertBefore(bar, tagline);
    else brand.insertBefore(bar, brand.firstChild);
  }

  function inject() {
    var brand = document.querySelector(".brand");
    if (!brand) return;

    if (onResetPage() || onUpgradePage()) {
      if (!document.getElementById("theme-toggle")) placeThemeInBrand(brand);
      applyBrand("node");
      return;
    }

    if (onSetupPage()) {
      if (!document.getElementById("theme-toggle")) placeThemeInBrand(brand);
      /* IUE: hold neutral brand until Setup Node step confirms Knots/Core */
      applyBrand("node");
      watchFactoryReset();
      return;
    }

    if (document.getElementById("topnav")) return;

    gateSetup();
    watchFactoryReset();
    placeThemeInBrand(brand);
    refreshBrand();

    var nav = document.createElement("nav");
    nav.id = "topnav";
    nav.className = "topnav";
    nav.setAttribute("aria-label", "Appliance sections");

    var primary = document.createElement("div");
    primary.className = "topnav-primary";

    var p = path();
    for (var i = 0; i < items.length; i++) {
      var it = items[i];
      var a = document.createElement("a");
      a.className = "nav-item" + (it.match.test(p) ? " active" : "");
      a.href = applianceUrl(it.href);
      a.textContent =
        window.KnotsI18n && it.i18n ? window.KnotsI18n.t(it.i18n) : it.label;
      primary.appendChild(a);
    }

    var luciA = document.createElement("a");
    luciA.className = "nav-item nav-luci";
    luciA.href = luciUrl();
    luciA.textContent =
      window.KnotsI18n ? window.KnotsI18n.t("nav.luci") : "Router settings";
    luciA.title = "LuCI — password required";

    nav.appendChild(primary);
    nav.appendChild(luciA);
    brand.insertAdjacentElement("afterend", nav);
    ensureBuildStrip(nav);
  }

  function relabelNav() {
    var nav = document.getElementById("topnav");
    if (!nav || !window.KnotsI18n) return;
    var links = nav.querySelectorAll(".topnav-primary .nav-item");
    var i;
    for (i = 0; i < items.length && i < links.length; i++) {
      if (items[i].i18n) links[i].textContent = window.KnotsI18n.t(items[i].i18n);
    }
    var luciA = nav.querySelector(".nav-luci");
    if (luciA) luciA.textContent = window.KnotsI18n.t("nav.luci");
  }

  function startShell() {
    ensureCleartextIue();
    /* Paint chrome immediately — do not wait on /ui-lang or i18n JSON.
       A failed JSON parse used to skip inject() and leave Node Status half-drawn. */
    inject();
    if (window.KnotsI18n) {
      window.KnotsI18n.detectInitial()
        .then(function () {
          relabelNav();
        })
        .catch(function () {
          /* English labels already on screen */
        });
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", startShell);
  } else {
    startShell();
  }
})();
