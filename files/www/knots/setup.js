/* SPDX-License-Identifier: GPL-2.0-only */
/* First-run Setup — U17 / TECH_SPEC §7.6 (Node Status look & feel)
   Flow (IUE v2): 0 Welcome → 1 Security (HTTP→trust) → 2 Choice (locale confirm)
   → Quick Start (3) | Guided: 4 Node → 5 WAN → 6 LAN → 7 Wi‑Fi → 8 Password → 9 Done */
(function () {
  var step = 0;
  var TOTAL = 10; /* 0..9 — U17 IUE v2 */
  var regionsCatalog = null;
  var dhcpTimer = null;
  var dhcpTries = 0;
  var quickWanTimer = null;
  var quickPppoeShown = false;
  var tlsWatchTimer = null;
  var FACTORY_PASS = "knotsnode21";

  function isFactoryPass(s) {
    return String(s || "") === FACTORY_PASS;
  }

  function $(id) {
    return document.getElementById(id);
  }

  /* D2: one host rule for the whole UI (shell.js KnotsIue.host). */
  function applianceHost() {
    return (window.KnotsIue ? window.KnotsIue.host() : "rnode.local");
  }

  function banner(msg, isErr) {
    var el = $("banner");
    if (!msg) {
      el.hidden = true;
      el.textContent = "";
      return;
    }
    el.hidden = false;
    el.textContent = msg;
    el.className = isErr ? "error" : "muted";
  }

  /* Green when a confirm pair matches; light red until then (U17). */
  function bindPasswordMatch(id1, id2) {
    var a = $(id1);
    var b = $(id2);
    if (!a || !b) return;
    function sync() {
      var v1 = a.value || "";
      var v2 = b.value || "";
      var ok = v1.length > 0 && v2.length > 0 && v1 === v2;
      a.classList.toggle("pw-match", ok);
      b.classList.toggle("pw-match", ok);
      a.classList.toggle("need-value", !ok);
      b.classList.toggle("need-value", !ok);
    }
    a.addEventListener("input", sync);
    b.addEventListener("input", sync);
    sync();
  }

  /* Single required field: red while empty, green once it has a value. */
  function bindNeedValue(id) {
    var el = $(id);
    if (!el) return;
    function sync() {
      var filled = (el.value || "").trim().length > 0;
      el.classList.toggle("pw-match", filled);
      el.classList.toggle("need-value", !filled);
    }
    el.addEventListener("input", sync);
    sync();
  }

  function markNeedValue(id) {
    var el = $(id);
    if (!el) return;
    el.dispatchEvent(new Event("input"));
  }

  function bindPasswordReveals() {
    var buttons = document.querySelectorAll("[data-pw-toggle]");
    for (var i = 0; i < buttons.length; i++) {
      (function (btn) {
        btn.addEventListener("click", function () {
          var id = btn.getAttribute("data-pw-toggle");
          var input = id ? $(id) : null;
          if (!input) return;
          var show = input.type === "password";
          input.type = show ? "text" : "password";
          btn.textContent = show ? "Hide" : "Show";
          btn.setAttribute("aria-pressed", show ? "true" : "false");
          btn.setAttribute("aria-label", show ? "Hide password" : "Show password");
        });
      })(buttons[i]);
    }
  }

  function stopTlsWatch() {
    if (tlsWatchTimer) {
      clearInterval(tlsWatchTimer);
      tlsWatchTimer = null;
    }
  }

  /* TLS watch / I’ve-finished must not yank the wizard back to Choice after
     the visitor has already opened Quick Start or Guided (U17). */
  function advancePastTls() {
    stopTlsWatch();
    if (step !== 1) return;
    enterChoice();
  }

  /* Setup is for a laptop or computer (owner decision 2026-10-25): the first
     step installs the secure-connection certificate, which Android and iOS
     only allow through several Settings screens. Phones and tablets get one
     clear message instead of a wizard they would get stuck in. */
  var ON_PHONE = !!(window.KnotsTlsOs && window.KnotsTlsOs.isPhoneOrTablet());

  function showStep(n) {
    if (ON_PHONE) {
      var all = document.querySelectorAll(".setup-step");
      for (var j = 0; j < all.length; j++) all[j].hidden = true;
      if ($("phoneOnly")) $("phoneOnly").hidden = false;
      if ($("progressLabel")) $("progressLabel").hidden = true;
      return;
    }
    if (n !== 1) stopTlsWatch();
    step = n;
    var panels = document.querySelectorAll(".setup-step");
    for (var i = 0; i < panels.length; i++) {
      var p = panels[i];
      var sn = parseInt(p.getAttribute("data-step"), 10);
      p.hidden = sn !== n;
    }
    if ($("stepRestart")) $("stepRestart").hidden = true;
    $("progressLabel").textContent = window.KnotsI18n
      ? window.KnotsI18n.t("setup.progress", { n: n + 1, total: TOTAL })
      : "Step " + (n + 1) + " of " + TOTAL;
    banner("");
  }

  function friendlyError(e) {
    var n = (e && e.name) || "";
    var m = String((e && e.message) || e || "");
    if (n === "AbortError" || /aborted/i.test(m)) {
      return "The router did not answer in time. Stay on this Wi-Fi and tap Save again.";
    }
    if (/Failed to fetch|NetworkError|Load failed|network/i.test(m)) {
      return "Lost the connection to the router. Rejoin Wi-Fi rnode and tap Save again.";
    }
    return m;
  }

  function api(action, opts) {
    opts = opts || {};
    var q = "/api/setup?action=" + encodeURIComponent(action);
    if (opts.query) q += "&" + opts.query;
    var init = { cache: "no-store", method: opts.method || "GET" };
    if (opts.body) {
      init.method = "POST";
      init.headers = { "Content-Type": "application/x-www-form-urlencoded" };
      init.body = opts.body;
    }
    var abortTimer = null;
    if (opts.timeoutMs && typeof AbortController !== "undefined") {
      var ctrl = new AbortController();
      init.signal = ctrl.signal;
      abortTimer = setTimeout(function () {
        try {
          ctrl.abort();
        } catch (e) {}
      }, opts.timeoutMs);
    }
    /* nginx answers 502 itself when the API backend (uhttpd) is briefly
       restarting, e.g. right after a firmware upgrade boots. The request never
       reached the CGI, so it is safe to retry; a 502 from uhttpd (the CGI ran
       and died) does not mention nginx and is not retried. */
    var gatewayRetries = opts.gatewayRetries != null ? opts.gatewayRetries : 4;
    function attempt() {
      return fetch(q, init).then(function (r) {
        if (r.status !== 502 || gatewayRetries <= 0) return r;
        return r.text().then(function (t) {
          if (!/nginx/i.test(t || "")) {
            return { status: r.status, text: function () { return Promise.resolve(t); } };
          }
          gatewayRetries -= 1;
          return new Promise(function (res) {
            setTimeout(res, 3000);
          }).then(attempt);
        });
      });
    }
    /* A network-level failure ("Failed to fetch") happens when nginx reloads
       and closes the keep-alive connection a POST was sent on — the request
       never reached the router. Retry once for actions that are safe to
       repeat; never for complete / quickstart (not idempotent). */
    var networkRetrySafe = /^(status|wan_status|locale|password|wan_dhcp|wan_pppoe|lan|wifi|node)$/.test(action);
    var networkRetried = false;
    function attemptWithNetRetry() {
      return attempt().catch(function (e) {
        if (!networkRetrySafe || networkRetried || (e && e.name === "AbortError")) throw e;
        networkRetried = true;
        return new Promise(function (res) {
          setTimeout(res, 1500);
        }).then(attempt);
      });
    }
    return attemptWithNetRetry()
      .then(function (r) {
        if (abortTimer) clearTimeout(abortTimer);
        return r.text().then(function (t) {
          var d;
          try {
            d = JSON.parse(t);
          } catch (e) {
            // After Setup the router locks this API on https (nginx 404). A
            // bookmarked / restored Setup tab must not show raw nginx pages
            // (.97 field report): explain and go to Node Status.
            if (r.status === 404) {
              setTimeout(function () { window.location.replace("/"); }, 4000);
              throw new Error("Setup is already complete on this router. Opening Node Status…");
            }
            throw new Error(
              "Setup API returned non-JSON (HTTP " + r.status + "). " + (t || "").slice(0, 120)
            );
          }
          if (!d) throw new Error("Bad response");
          return d;
        });
      })
      .catch(function (e) {
        if (abortTimer) clearTimeout(abortTimer);
        throw e;
      });
  }

  function formBody(obj) {
    var parts = [];
    Object.keys(obj).forEach(function (k) {
      parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(obj[k]));
    });
    return parts.join("&");
  }

  function hideWanButtons() {
    $("btnWanContinue").hidden = true;
    $("btnWanRetry").hidden = true;
    $("btnWanPppoe").hidden = true;
    $("btnWanSkip").hidden = true;
  }

  function startDhcpTry() {
    hideWanButtons();
    $("pppoeBox").hidden = true;
    $("wanCopy").textContent = "Connecting with DHCP (typical home modem)…";
    $("wanState").textContent = "Checking…";
    $("wanState").className = "state busy";
    dhcpTries = 0;
    api("wan_dhcp", { method: "POST", body: "" })
      .then(function () {
        pollWan();
      })
      .catch(function (e) {
        wanFail(String(e.message || e));
      });
  }

  function pollWan() {
    if (dhcpTimer) clearInterval(dhcpTimer);
    dhcpTimer = setInterval(function () {
      dhcpTries += 1;
      api("wan_status")
        .then(function (d) {
          if (d.up && d.ipv4) {
            clearInterval(dhcpTimer);
            dhcpTimer = null;
            $("wanCopy").textContent = "Internet connected.";
            $("wanState").textContent = "Address " + d.ipv4 + " (" + (d.proto || "dhcp") + ")";
            $("wanState").className = "state";
            $("btnWanContinue").hidden = false;
            $("btnWanSkip").hidden = true;
            $("btnWanPppoe").hidden = true;
            $("btnWanRetry").hidden = true;
            return;
          }
          if (dhcpTries >= 12) {
            clearInterval(dhcpTimer);
            dhcpTimer = null;
            wanFail("No address yet — check the WAN cable, or your ISP may need a login.");
          } else {
            $("wanState").textContent = "Still checking… (" + dhcpTries + ")";
          }
        })
        .catch(function () {
          /* keep polling */
        });
    }, 2000);
  }

  function wanFail(msg) {
    $("wanCopy").textContent = msg;
    $("wanState").textContent = "";
    $("wanState").className = "state";
    $("btnWanRetry").hidden = false;
    $("btnWanPppoe").hidden = false;
    $("btnWanSkip").hidden = false;
    $("btnWanContinue").hidden = true;
  }

  function enterWifi(st) {
    if (st && st.wifi_available === false) {
      $("wifiCopy").textContent = window.KnotsI18n
        ? window.KnotsI18n.t("setup.wifi.none")
        : "Wi‑Fi is not available on this unit.";
      $("wifiForm").hidden = true;
      $("btnWifiSkip").hidden = false;
    } else {
      $("wifiCopy").textContent = window.KnotsI18n
        ? window.KnotsI18n.t("setup.wifi.body")
        : "Choose a new Wi‑Fi password (required — not the factory password). The network name defaults to rnode.";
      if (st && st.client_wifi) {
        $("wifiCopy").textContent =
          "You are on Wi‑Fi. After you save, this device will disconnect. Join the new network name with the new password — Setup will continue when you are back.";
      }
      $("wifiForm").hidden = false;
      if ($("wifiSteps")) $("wifiSteps").hidden = false;
      if ($("wifiWait")) $("wifiWait").hidden = true;
      if ($("wifiSsid") && !$("wifiSsid").value) $("wifiSsid").value = "rnode";
      if ($("wifiSsid") && ($("wifiSsid").value === "knwifi" || $("wifiSsid").value === "brnode")) $("wifiSsid").value = "rnode";
      $("btnWifiSkip").hidden = true;
      if (st && st.country && $("wifiCountry")) {
        $("wifiCountry").value = st.country;
        markNeedValue("wifiCountry");
      }
    }
    showStep(7);
  }

  /* Set once the user leaves Welcome. The boot status call can return AFTER
     a quick Continue (slow first CGI after a factory reset); its default
     "show Welcome" must not then throw the user back (.85 UAT-IQ-3). */
  var userLeftWelcome = false;
  function welcomeUnlessMoved() {
    if (!userLeftWelcome) showStep(0);
  }

  /* First-use captive portal: on a Mac, Setup may open in the "sign in to
     network" window (Captive Network Assistant: no "Safari/" token). It cannot
     download the certificate profile, so point to the normal browser. Windows
     opens the normal browser already. */
  function inCaptiveWindow() {
    var ua = navigator.userAgent || "";
    if (ON_PHONE) return false;
    if (/Macintosh/.test(ua) && /AppleWebKit/.test(ua) && !/Safari\//.test(ua)) return true;
    return false;
  }
  if (ON_PHONE) showStep(0);
  if ($("cnaHint") && inCaptiveWindow()) {
    $("cnaHint").hidden = false;
    if ($("cnaUrl")) $("cnaUrl").textContent = "http://" + location.host + "/";
  }

  $("btnWelcome").onclick = function () {
    userLeftWelcome = true;
    enterTlsTrust();
  };

  /* ---- locale: browser auto-detect (U19) + confirmation on the Choice page ---- */

  function detectBrowserLocale() {
    var det = { lang: "en", zonename: "" };
    try {
      det.zonename = Intl.DateTimeFormat().resolvedOptions().timeZone || "";
    } catch (e) {}
    try {
      var nav = (navigator.language || "en").toLowerCase();
      var map = {
        en: "en", es: "es", de: "de", fr: "fr", ja: "ja", pt: "pt-br",
        "pt-br": "pt-br", zh: "zh-cn", "zh-cn": "zh-cn", "zh-hans": "zh-cn"
      };
      det.lang = map[nav] || map[nav.split("-")[0]] || "en";
    } catch (e) {}
    return det;
  }

  function fillLocaleSelectors(pre) {
    pre = pre || {};
    return fetch("/i18n/regions.json", { cache: "no-store" })
      .then(function (r) {
        return r.json();
      })
      .then(function (cat) {
        regionsCatalog = cat;
        var langSel = $("localeLang");
        var tzSel = $("localeTimezone");
        if (!langSel || !tzSel) return;
        langSel.innerHTML = "";
        (cat.languages || []).forEach(function (L) {
          var o = document.createElement("option");
          o.value = L.id;
          o.textContent = L.label;
          langSel.appendChild(o);
        });
        tzSel.innerHTML = "";
        (cat.regions || []).forEach(function (R) {
          var o = document.createElement("option");
          o.value = R.zonename || "";
          o.textContent = (R.zonename || "") + " — " + R.name + " (" + R.cc + ")";
          o.setAttribute("data-country", R.cc || "");
          tzSel.appendChild(o);
        });
        if (pre.lang) langSel.value = pre.lang;
        if (pre.zonename) {
          tzSel.value = pre.zonename;
        }
        if (!tzSel.value && pre.country) {
          for (var i = 0; i < tzSel.options.length; i++) {
            if (tzSel.options[i].getAttribute("data-country") === pre.country) {
              tzSel.selectedIndex = i;
              break;
            }
          }
        }
        if (!tzSel.value && tzSel.options.length) tzSel.selectedIndex = 0;
        updateCountryShow();
      });
  }

  function updateCountryShow() {
    var tzSel = $("localeTimezone");
    var show = $("localeCountryShow");
    if (!tzSel || !show) return;
    var opt = tzSel.options[tzSel.selectedIndex];
    show.textContent = (opt && opt.getAttribute("data-country")) || "—";
  }

  function localeSelection() {
    var lang = ($("localeLang") && $("localeLang").value || "en").trim();
    var zonename = ($("localeTimezone") && $("localeTimezone").value || "").trim();
    var country = "";
    var opt = $("localeTimezone") && $("localeTimezone").options[$("localeTimezone").selectedIndex];
    if (opt) country = (opt.getAttribute("data-country") || "").trim();
    return { lang: lang, country: country, zonename: zonename };
  }

  function applyLocaleFromSelectors() {
    var sel = localeSelection();
    if (!sel.zonename) return Promise.resolve({ ok: true });
    return api("locale", {
      body: formBody({ lang: sel.lang, country: sel.country, zonename: sel.zonename })
    }).then(function (d) {
      if ($("wifiCountry") && sel.country) {
        $("wifiCountry").value = sel.country;
        markNeedValue("wifiCountry");
      }
      if (window.KnotsI18n) return window.KnotsI18n.loadLang(sel.lang);
    });
  }

  function enterChoice() {
    showStep(2);
    var det = detectBrowserLocale();
    fillLocaleSelectors({ lang: det.lang, zonename: det.zonename }).then(function () {
      var sel = localeSelection();
      var langSel = $("localeLang");
      var langLabel = sel.lang;
      if (langSel && langSel.options[langSel.selectedIndex]) {
        langLabel = langSel.options[langSel.selectedIndex].textContent;
      }
      $("choiceLocaleLine").textContent =
        "Language & timezone (from your browser): " + langLabel +
        " · " + (sel.zonename || "UTC");
    });
  }

  if ($("localeTimezone")) {
    $("localeTimezone").addEventListener("change", updateCountryShow);
  }
  if ($("localeLang")) {
    $("localeLang").addEventListener("change", function () {
      var code = $("localeLang").value;
      if (window.KnotsI18n) {
        window.KnotsI18n.loadLang(code).then(function () {
          if (step === 2) showStep(2);
        });
      }
    });
  }

  /* ---- Choice: Quick Start vs Guided Setup ---- */

  $("btnGuided").onclick = function () {
    applyLocaleFromSelectors()
      .catch(function () {})
      .then(function () {
        showStep(4);
      });
  };

  $("btnQuick").onclick = function () {
    enterQuick();
  };

  /* ---- Quick Start (step 3) ---- */

  function setQuickWan(msg, cls) {
    var el = $("quickWanState");
    if (!el) return;
    el.textContent = msg;
    el.className = "state" + (cls ? " " + cls : "");
  }

  function enterQuick() {
    showStep(3);
    quickPppoeShown = false;
    if ($("quickPppoeModal")) $("quickPppoeModal").hidden = true;
    api("status")
      .then(function (st) {
        if (st && st.wifi_available === false && $("quickWifiForm")) {
          $("quickWifiForm").hidden = true;
        }
      })
      .catch(function () {});
    setQuickWan("Checking your internet connection (automatic)…", "busy");
    api("wan_dhcp", { method: "POST", body: "" })
      .then(function () {
        pollQuickWan(0);
      })
      .catch(function () {
        quickWanDown();
      });
  }

  function pollQuickWan(tries) {
    if (quickWanTimer) clearTimeout(quickWanTimer);
    quickWanTimer = setTimeout(function () {
      api("wan_status")
        .then(function (d) {
          if (d.up && d.ipv4) {
            setQuickWan("Internet connected (" + d.ipv4 + ").", "ok");
            return;
          }
          if (tries >= 9) {
            quickWanDown();
            return;
          }
          pollQuickWan(tries + 1);
        })
        .catch(function () {
          pollQuickWan(tries + 1);
        });
    }, 2000);
  }

  function quickWanDown() {
    setQuickWan("No internet address yet — you can still finish setup and configure internet later.", "");
    if ($("quickPppoeModal") && !quickPppoeShown) {
      quickPppoeShown = true;
      $("quickPppoeModal").hidden = false;
    }
  }

  if ($("btnQuickPppoe")) {
    $("btnQuickPppoe").onclick = function () {
      var u = ($("quickPppoeUser").value || "").trim();
      var p = $("quickPppoePass").value || "";
      if (!u || !p) {
        banner("Enter ISP username and password.", true);
        return;
      }
      api("wan_pppoe", { body: formBody({ username: u, password: p }) })
        .then(function (d) {
          if (!d.ok) {
            banner(d.message || d.error, true);
            return;
          }
          $("quickPppoeModal").hidden = true;
          setQuickWan("Connecting with ISP login…", "busy");
          pollQuickWan(0);
        })
        .catch(function (e) {
          banner(String(e.message || e), true);
        });
    };
  }
  if ($("btnQuickPppoeSkip")) {
    $("btnQuickPppoeSkip").onclick = function () {
      $("quickPppoeModal").hidden = true;
    };
  }

  $("btnQuickSubmit").onclick = function () {
    /* C8: passwords are used exactly as typed (no trim) — the router stores
       them byte-for-byte, so a trimmed copy would not match at login. */
    var p1 = $("quickPw1").value || "";
    var p2 = $("quickPw2").value || "";
    var wk = $("quickWifiKey") ? $("quickWifiKey").value || "" : "";
    var wk2 = $("quickWifiKey2") ? $("quickWifiKey2").value || "" : "";
    var wifiHidden = $("quickWifiForm") && $("quickWifiForm").hidden;
    if (p1.length < 8) {
      banner("Router password must be at least 8 characters.", true);
      return;
    }
    if (p1 !== p2) {
      banner("Router passwords do not match.", true);
      return;
    }
    if (!wifiHidden) {
      if (wk.length < 8 || wk.length > 63) {
        banner("Wi‑Fi password must be 8–63 characters (WPA2 standard).", true);
        return;
      }
      if (isFactoryPass(wk)) {
        banner("Choose a new Wi‑Fi password — not the factory default.", true);
        return;
      }
      if (wk !== wk2) {
        banner("Wi‑Fi passwords do not match.", true);
        return;
      }
    }
    var sel = localeSelection();
    $("btnQuickSubmit").disabled = true;
    api("quickstart", {
      body: formBody({
        lang: sel.lang,
        country: sel.country,
        zonename: sel.zonename,
        password: p1,
        password2: p2,
        wifipsk: wk
      })
    })
      .then(function (d) {
        if (!d.ok) {
          $("btnQuickSubmit").disabled = false;
          banner(d.message || d.error, true);
          return;
        }
        followLan(d);
        if (d.wifi_reconnect || d.lan_moved) {
          showFinishWait({
            ssid: d.ssid || "rnode",
            lanMoved: !!d.lan_moved,
            lanIp: d.lan_ip,
            dest: nodeStatusUrl(d.redirect)
          });
          return;
        }
        location.href = nodeStatusUrl(d.redirect);
      })
      .catch(function (e) {
        $("btnQuickSubmit").disabled = false;
        banner(String(e.message || e), true);
      });
  };

  /* ---- Guided path (4 Node → 5 WAN → 6 LAN → 7 Wi‑Fi → 8 Password → 9 Done) ---- */

  $("btnPassword").onclick = function () {
    var p1 = $("pw1").value || "";
    var p2 = $("pw2").value || "";
    if (p1.length < 8) {
      banner("Password must be at least 8 characters.", true);
      return;
    }
    if (p1 !== p2) {
      banner("Passwords do not match.", true);
      return;
    }
    $("btnPassword").disabled = true;
    api("password", {
      body: formBody({ password: p1, password2: p2 }),
      timeoutMs: 12000
    })
      .then(function (d) {
        $("btnPassword").disabled = false;
        if (!d.ok) {
          banner(d.message || d.error || "Failed", true);
          return;
        }
        showStep(9);
      })
      .catch(function (e) {
        api("status")
          .then(function (st) {
            if (st && st.password_done) {
              showStep(9);
              return;
            }
            $("btnPassword").disabled = false;
            banner(String(e.message || e), true);
          })
          .catch(function () {
            $("btnPassword").disabled = false;
            banner(String(e.message || e), true);
          });
      });
  };

  $("btnWanContinue").onclick = function () {
    enterAdvanced();
  };
  $("btnWanRetry").onclick = function () {
    startDhcpTry();
  };
  $("btnWanPppoe").onclick = function () {
    $("pppoeBox").hidden = false;
    hideWanButtons();
    $("btnWanSkip").hidden = false;
  };
  $("btnWanSkip").onclick = function () {
    if (dhcpTimer) {
      clearInterval(dhcpTimer);
      dhcpTimer = null;
    }
    enterAdvanced();
  };
  $("btnPppoe").onclick = function () {
    var u = ($("pppoeUser").value || "").trim();
    var p = $("pppoePass").value || "";
    if (!u || !p) {
      banner("Enter ISP username and password.", true);
      return;
    }
    api("wan_pppoe", { body: formBody({ username: u, password: p }) })
      .then(function (d) {
        if (!d.ok) {
          banner(d.message || d.error, true);
          return;
        }
        $("pppoeBox").hidden = true;
        $("wanCopy").textContent = "Connecting with ISP login…";
        dhcpTries = 0;
        pollWan();
      })
      .catch(function (e) {
        banner(String(e.message || e), true);
      });
  };

  $("btnWifi").onclick = function () {
    var ssid = ($("wifiSsid").value || "rnode").trim();
    var key = $("wifiKey").value || "";
    var key2 = ($("wifiKey2") && $("wifiKey2").value) || "";
    var country = ($("wifiCountry").value || "").trim().toUpperCase();
    if (!ssid || ssid.length > 32) {
      banner("Network name must be 1–32 characters.", true);
      return;
    }
    /* IEEE 802.11i / WPA2-Personal passphrase: 8–63 ASCII */
    if (key.length < 8 || key.length > 63) {
      banner("Wi‑Fi password must be 8–63 characters (WPA2 standard).", true);
      return;
    }
    if (isFactoryPass(key)) {
      banner("Choose a new Wi‑Fi password — not the factory default.", true);
      return;
    }
    if (key !== key2) {
      banner("Wi‑Fi passwords do not match.", true);
      return;
    }
    if (country.length !== 2) {
      banner("Enter a 2-letter country code (e.g. AU).", true);
      return;
    }
    $("btnWifi").disabled = true;
    if ($("wifiForm")) $("wifiForm").hidden = true;
    if ($("wifiSteps")) $("wifiSteps").hidden = true;
    var wait = $("wifiWait");
    var bar = $("wifiWaitBar");
    var lab = $("wifiWaitLabel");
    if (wait) wait.hidden = false;
    if (bar) bar.value = 6;
    if (lab) lab.textContent = "Saving Wi‑Fi… 0s";
    var wtick = 0;
    var advanced = false;
    var wiv = setInterval(function () {
      wtick += 1;
      if (bar) bar.value = Math.min(94, 6 + wtick * 10);
      if (lab) lab.textContent = "Saving Wi‑Fi… " + wtick + "s";
    }, 1000);
    function finishWifi(ok, msg) {
      if (advanced) return;
      advanced = true;
      clearInterval(wiv);
      if (ok) {
        if (bar) bar.value = 100;
        if (lab) lab.textContent = "Opening router password…";
        showStep(8);
        banner(
          msg ||
            "Wi‑Fi saved. It applies when you finish Setup. Set a router password next.",
          false
        );
        return;
      }
      if (wait) wait.hidden = true;
      if ($("wifiForm")) $("wifiForm").hidden = false;
      if ($("wifiSteps")) $("wifiSteps").hidden = false;
      $("btnWifi").disabled = false;
      banner(msg, true);
    }
    api("wifi", {
      body: formBody({ ssid: ssid, key: key, country: country })
    })
      .then(function (d) {
        if (!d.ok) {
          finishWifi(false, d.message || d.error);
          return;
        }
        finishWifi(true, d.message);
      })
      .catch(function (e) {
        api("status")
          .then(function (st) {
            if (st && st.wifi_staged) {
              finishWifi(true, "Wi-Fi saved. It applies when you finish Setup.");
              return;
            }
            finishWifi(false, friendlyError(e));
          })
          .catch(function () {
            finishWifi(false, friendlyError(e));
          });
      });
  };
  $("btnWifiSkip").onclick = function () {
    showStep(8);
  };

  $("btnNode").onclick = function () {
    var impl = "core";
    var radios = document.querySelectorAll('input[name="impl"]');
    for (var i = 0; i < radios.length; i++) {
      if (radios[i].checked) impl = radios[i].value;
    }
    /* Known issue in the shipped Knots (node-advisory.js): warn before it is
       chosen; "Use Bitcoin Core" switches the choice and carries on. */
    var adv = window.KnotsNodeAdvisory;
    if (impl === "knots" && adv) {
      $("btnNode").disabled = true;
      adv.confirmChoice("knots").then(function (goAhead) {
        $("btnNode").disabled = false;
        if (!goAhead) {
          var core = document.querySelector('input[name="impl"][value="core"]');
          if (core) core.checked = true;
        }
        submitNode(goAhead ? "knots" : "core");
      });
      return;
    }
    submitNode(impl);
  };

  function submitNode(impl) {
    $("btnNode").disabled = true;
    api("node", { body: formBody({ impl: impl }) })
      .then(function (d) {
        $("btnNode").disabled = false;
        if (!d.ok) {
          banner(d.message || d.error, true);
          return;
        }
        if (window.KnotsBrand) window.KnotsBrand.apply(impl);
        showStep(5);
        startDhcpTry();
      })
      .catch(function (e) {
        $("btnNode").disabled = false;
        banner(String(e.message || e), true);
      });
  }

  function enterTlsTrust() {
    var os = window.KnotsTlsOs ? window.KnotsTlsOs.detectOs() : "linux";
    applyTlsOsLayout(os);
    showStep(1);
    if (window.KnotsTlsOs) {
      window.__knotsRouterHttp = window.KnotsTlsOs.routerHttpBase();
      window.KnotsTlsOs.bindOsTabs({ onShow: applyTlsOsLayout });
    }
    if ($("tlsLinuxOneLiner")) {
      var h = applianceHost();
      /* P4: download to a private temp file, then run it — never pipe a
         network download straight into a shell. The script only installs a
         CA restricted to this router and prints its fingerprint. */
      var oneLiner =
        'f=$(mktemp) && wget -qO "$f" http://' + h + '/tls/install-linux.sh && sh "$f" http://' + h;
      $("tlsLinuxOneLiner").textContent = oneLiner;
      if ($("tlsLinuxOneLinerWrap")) {
        $("tlsLinuxOneLinerWrap").setAttribute("data-copy", oneLiner);
        if (!$("tlsLinuxOneLinerWrap").__tlsWatchBound) {
          $("tlsLinuxOneLinerWrap").__tlsWatchBound = true;
          $("tlsLinuxOneLinerWrap").addEventListener("click", function (e) {
            startTlsWatch();
            /* Clicking the command box copies it (same path as the Copy button). */
            if (e.target && e.target.closest && e.target.closest(".btn-copy")) {
              return;
            }
            var btn = this.querySelector(".btn-copy");
            if (btn) btn.click();
          });
        }
      }
    }
    if ($("tlsMacOneLiner") && window.KnotsTlsOs) {
      var hm = applianceHost();
      var macLine = window.KnotsTlsOs.macTrustCommand(hm);
      $("tlsMacOneLiner").textContent = macLine;
      if ($("tlsMacOneLinerWrap")) {
        $("tlsMacOneLinerWrap").setAttribute("data-copy", macLine);
        if (!$("tlsMacOneLinerWrap").__tlsWatchBound) {
          $("tlsMacOneLinerWrap").__tlsWatchBound = true;
          $("tlsMacOneLinerWrap").addEventListener("click", function (e) {
            startTlsWatch();
            if (e.target && e.target.closest && e.target.closest(".btn-copy")) return;
            var btn = this.querySelector(".btn-copy");
            if (btn) btn.click();
          });
        }
      }
      /* Mac button = Script Editor link (Allow → ▶ Run → password). */
      if ($("tlsMacCta")) {
        $("tlsMacCta").href = window.KnotsTlsOs.macScriptEditorHref(hm);
        if (!$("tlsMacCta").__tlsWatchBound) {
          $("tlsMacCta").__tlsWatchBound = true;
          $("tlsMacCta").addEventListener("click", function () { startTlsWatch(); });
        }
      }
    }
    if ($("tlsHelp")) $("tlsHelp").open = false;
    /* Watch from step entry (not only after the download click): the Linux
       one-liner path never touches the download button. */
    startTlsWatch();
    function bindTlsCtaWatch(id) {
      var el = $(id);
      if (!el || el.__tlsWatchBound) return;
      el.__tlsWatchBound = true;
      el.addEventListener("click", function () {
        startTlsWatch();
      });
    }
    bindTlsCtaWatch("tlsPrimaryCta");
    bindTlsCtaWatch("tlsLinuxCta");
  }

  function applyTlsOsLayout(os) {
    var linux = os === "linux";
    var mac = os === "mac";
    var win = !linux && !mac;
    var own = linux || mac;               /* own button + steps; no shared download button */
    if ($("stepTls")) $("stepTls").classList.toggle("tls-os-linux", linux);
    /* Every OS has its numbered steps on screen (owner, 2026-10-25). */
    if ($("tlsDownloadTip")) $("tlsDownloadTip").hidden = true;
    if ($("tlsWinImportant")) $("tlsWinImportant").hidden = !win;
    if ($("tlsLinuxImportant")) $("tlsLinuxImportant").hidden = !linux;
    if ($("tlsLinuxCtaWrap")) $("tlsLinuxCtaWrap").hidden = !linux;
    if ($("tlsLinuxAlt")) $("tlsLinuxAlt").hidden = !linux;
    if ($("tlsLinuxQuick")) $("tlsLinuxQuick").hidden = !linux;
    if ($("tlsMacImportant")) $("tlsMacImportant").hidden = !mac;
    if ($("tlsMacCtaWrap")) $("tlsMacCtaWrap").hidden = !mac;
    if ($("tlsMacAlt")) $("tlsMacAlt").hidden = !mac;
    if ($("tlsMacQuick")) $("tlsMacQuick").hidden = !mac;
    if ($("tlsTopCtaWrap")) $("tlsTopCtaWrap").hidden = own;
    if ($("tlsPrimaryHint")) $("tlsPrimaryHint").hidden = true;
    if ($("tlsHelp")) $("tlsHelp").open = false;
  }

  function enterAdvanced() {
    api("status").then(function (st) {
      if (st.lan) {
        $("lanIp").value = st.lan.ipaddr || "192.168.1.254";
        $("lanMask").value = st.lan.netmask || "255.255.255.0";
        $("lanDhcpStart").value = st.lan.dhcp_start || "100";
        $("lanDhcpLimit").value = st.lan.dhcp_limit || "101";
      }
      showStep(6);
    }).catch(function () {
      showStep(6);
    });
  }

  /* After cert install: require Node :443 trust in this browser.
     Probe Router settings :8443 as advisory only — a hard requirement blocked
     Continue when LuCI was slow/unreachable even after a good CA install (F84). */
  function httpsProbeUrl() {
    return "https://" + applianceHost() + "/api/setup?action=status&_=" + Date.now();
  }

  function luciProbeUrl() {
    return "https://" + applianceHost() + ":8443/cgi-bin/luci/?_=" + Date.now();
  }

  function setTlsVerifyUi(msg, busy) {
    var hint = $("tlsPrimaryHint");
    if (hint) {
      hint.textContent = msg || "";
      hint.className = busy ? "state busy" : "muted";
    }
    banner(msg || "", false);
  }

  function probeUrl(url, mode, timeoutMs) {
    return new Promise(function (resolve) {
      var ctrl = typeof AbortController !== "undefined" ? new AbortController() : null;
      var settled = false;
      var done = function (v) {
        if (settled) return;
        settled = true;
        clearTimeout(t);
        resolve(!!v);
      };
      var t = setTimeout(function () {
        if (ctrl) {
          try {
            ctrl.abort();
          } catch (e) {}
        }
        done(false);
      }, timeoutMs || 10000);
      var init = { cache: "no-store", credentials: "omit", mode: mode || "cors" };
      if (ctrl) init.signal = ctrl.signal;
      fetch(url, init)
        .then(function (r) {
          if (mode === "no-cors") {
            done(true);
            return;
          }
          if (!r.ok) {
            done(false);
            return;
          }
          return r.json().then(
            function (d) {
              done(!!(d && d.ok !== false));
            },
            function () {
              done(false);
            }
          );
        })
        .catch(function () {
          done(false);
        });
    });
  }

  function verifyHttpsTrust(cb) {
    probeUrl(httpsProbeUrl(), "cors", 10000).then(function (nodeOk) {
      if (!nodeOk) {
        cb(false, { node: false, luci: false });
        return;
      }
      /* Node OK — brief LuCI check; never block Continue on LuCI alone */
      probeUrl(luciProbeUrl(), "no-cors", 2500).then(function (luciOk) {
        cb(true, { node: true, luci: !!luciOk });
      });
    });
  }

  function softReloadAfterTrust() {
    try {
      sessionStorage.setItem("knots_tls_continue", "1");
      sessionStorage.setItem("knots_tls_reloaded", "1");
    } catch (e) {}
    location.replace("https://" + applianceHost() + "/setup.html?after_tls=1");
  }

  /* Progress UI for the download-run install (U17 page 2). The bar tracks
     probe stages honestly: download → waiting for the installer → verifying
     → secured. The page cannot see the installer's own progress (it runs on
     the visitor's computer, outside the browser sandbox). */
  function tlsProgress(pct, msg) {
    var box = $("tlsProgress");
    if (!box) return;
    if (!msg) {
      box.hidden = true;
      return;
    }
    box.hidden = false;
    if ($("tlsProgressBar")) $("tlsProgressBar").value = pct;
    if ($("tlsProgressLabel")) $("tlsProgressLabel").textContent = msg;
  }

  function startTlsWatch() {
    tlsProgress(15, "Run the Terminal command (Linux box) or the downloaded file — nothing installs by itself. Watching…");
    var tries = 0;
    var inFlight = false;
    if (tlsWatchTimer) clearInterval(tlsWatchTimer);
    function stop() {
      if (tlsWatchTimer) clearInterval(tlsWatchTimer);
      tlsWatchTimer = null;
    }
    /* H6 (review 2026-10-11): one probe at a time (a 4 s probe on a 3 s tick
       used to overlap), and a verify failure keeps watching with a real
       message instead of an empty (hidden) one. */
    tlsWatchTimer = setInterval(function () {
      if (inFlight) return;
      inFlight = true;
      tries += 1;
      probeUrl(httpsProbeUrl(), "no-cors", 4000).then(function (ok) {
        if (!ok) {
          inFlight = false;
          if (tries === 1) {
            tlsProgress(35, "Still waiting for you to run the installer in a Terminal — the password prompt appears in the Terminal, never here.");
          } else if (tries >= 100) {
            stop();
            tlsProgress(40, tlsStalledText());
          }
          return;
        }
        tlsProgress(90, "Secure connection detected — verifying…");
        verifyHttpsTrust(function (vok) {
          inFlight = false;
          if (!vok) {
            tlsProgress(40, tlsStalledText());
            return;
          }
          stop();
          tlsProgress(100, "Secure connection ready — opening the secure page…");
          if (location.protocol === "https:") {
            if (step === 1) finishTlsTrust({});
          } else {
            softReloadAfterTrust();
          }
        });
      });
    }, 3000);
  }

  function tlsStalledText() {
    return "The browser does not trust the router yet. Finish the installer (it asks for your computer password in the Terminal or a system dialog), then restart the browser if it was open during the install. Or use Skip to continue without HTTPS.";
  }

  function finishTlsTrust(opts) {
    opts = opts || {};
    var skipVerify = !!opts.skip;
    if (skipVerify) {
      advancePastTls();
      return;
    }
    if ($("btnTlsContinue")) $("btnTlsContinue").disabled = true;
    if ($("btnTlsSkip")) $("btnTlsSkip").disabled = true;
    setTlsVerifyUi("Checking secure connection…", true);
    /* no-cors probe first: it resolves whenever the TLS handshake completes
       (CA installed) and rejects on cert/network failure. This detects
       "certificate not installed yet" and guides inline — the previous flow
       navigated straight into the browser's cert-error page, which read as
       "the button does nothing" (IUE Step 2 regression report). */
    probeUrl(httpsProbeUrl(), "no-cors", 8000).then(function (tlsOk) {
      if (!tlsOk) {
        if ($("btnTlsContinue")) $("btnTlsContinue").disabled = false;
        if ($("btnTlsSkip")) $("btnTlsSkip").disabled = false;
        var msg =
          location.protocol === "https:"
            ? "Secure connection is not reachable right now. Wait a moment and tap I’ve finished again — or Skip for now and finish trust later."
            : tlsStalledText();
        setTlsVerifyUi(msg, false);
        if (msg) banner(msg, true);
        tlsProgress(40, msg);
        return;
      }
      verifyHttpsTrust(function (ok, detail) {
        detail = detail || {};
        if (ok) {
          try {
            sessionStorage.removeItem("knots_tls_continue");
            sessionStorage.removeItem("knots_tls_reloaded");
          } catch (e) {}
          if ($("btnTlsContinue")) $("btnTlsContinue").disabled = false;
          if ($("btnTlsSkip")) $("btnTlsSkip").disabled = false;
          if (detail.luci) {
            setTlsVerifyUi("Secure connection OK — continuing…", false);
          } else {
            setTlsVerifyUi(
              "Secure connection OK. If Router settings still warns later, fully quit the browser once.",
              false
            );
          }
          advancePastTls();
          return;
        }
        var already;
        try {
          already = sessionStorage.getItem("knots_tls_reloaded") === "1";
        } catch (e2) {
          already = false;
        }
        if (!already) {
          setTlsVerifyUi("Reopening this page securely so the new certificate applies…", true);
          softReloadAfterTrust();
          return;
        }
        if ($("btnTlsContinue")) $("btnTlsContinue").disabled = false;
        if ($("btnTlsSkip")) $("btnTlsSkip").disabled = false;
        enterTlsTrust();
        var tip =
          "Secure check still pending. Fully quit the browser (all windows), reopen this Setup page, " +
          "then tap I’ve finished again — or Skip for now and finish trust later.";
        setTlsVerifyUi(tip, false);
        banner(tip, true);
        tlsProgress(40, tip);
      });
    });
  }

  if ($("btnTlsContinue")) {
    $("btnTlsContinue").onclick = function () {
      finishTlsTrust({});
    };
  }
  if ($("btnTlsSkip")) {
    $("btnTlsSkip").onclick = function () {
      finishTlsTrust({ skip: true });
    };
  }

  /*
   * API d.redirect / LAN-IP values flow into location.href and anchors —
   * allow only http(s):// or root-relative paths (no "javascript:", no
   * protocol-relative "//host"); else fall back to "/".
   */
  function safeDest(u) {
    u = String(u || "");
    if (/^https:\/\//i.test(u) || /^http:\/\//i.test(u)) return u;
    if (/^\/(?!\/)/.test(u)) return u;
    return "/";
  }

  /* D2: the API's redirect names a PATH; the host is the one this browser
     reached us by (an IP host follows a LAN move — KnotsIue.followLanIp). */
  function nodeStatusUrl(apiRedirect) {
    var dest = safeDest(apiRedirect || "/");
    var path = dest.replace(/^https?:\/\/[^/]*/i, "") || "/";
    if (path.charAt(0) !== "/") path = "/" + path;
    if (path.indexOf("/setup.html") === 0) return "http://" + applianceHost() + path;
    return "https://" + applianceHost() + path;
  }

  /* Finish moved the LAN: an IP-addressed tab must follow the new IP. */
  function followLan(d) {
    if (d && d.lan_moved && d.lan_ip && window.KnotsIue && window.KnotsIue.followLanIp) {
      window.KnotsIue.followLanIp(d.lan_ip);
    }
  }

  function setWaitProgress(pct, msg) {
    var wrap = $("waitProgress");
    var bar = $("waitProgressBar");
    var lab = $("waitProgressLabel");
    if (wrap) wrap.hidden = false;
    if (bar) bar.value = Math.max(0, Math.min(100, pct));
    if (lab) lab.textContent = msg || "";
  }

  function showSetupWait(opts) {
    opts = opts || {};
    var proto = location.protocol === "https:" ? "https:" : "http:";
    var ip = String(opts.lanIp || "").replace(/[^0-9.]/g, "");
    var resumeName = opts.resumeName;
    var resumeIp = "";
    if (ip && resumeName) {
      resumeIp = resumeName.replace(/^https?:\/\/[^/]+/i, proto + "//" + ip);
    }
    var panels = document.querySelectorAll(".setup-step");
    for (var i = 0; i < panels.length; i++) {
      panels[i].hidden = true;
    }
    if ($("progressLabel")) $("progressLabel").textContent = opts.progressLabel || "Updating network";
    banner("");
    var box = $("stepRestart");
    if (box) box.hidden = false;
    if ($("restartTitle")) $("restartTitle").textContent = opts.title || "Please wait";
    if ($("restartCopy")) $("restartCopy").textContent = opts.copy || "";
    if ($("restartUrl")) {
      $("restartUrl").textContent = resumeIp ? resumeName + "  ·  " + resumeIp : resumeName || "";
    }
    var progress = opts.progress || "Waiting";
    if ($("restartState")) {
      $("restartState").textContent = progress + "… 0s";
      $("restartState").className = "state busy";
    }
    setWaitProgress(5, progress + "… 0s");
    var navigated = false;
    function go() {
      if (navigated) return;
      navigated = true;
      if ($("restartState")) {
        $("restartState").textContent = "Opening…";
        $("restartState").className = "state ok";
      }
      setWaitProgress(100, "Opening…");
      location.replace(resumeName);
    }
    /* C8: probe on this page's own protocol only — http:// probes from an
       https page are blocked as mixed content and never succeed. */
    var probes = [proto + "//" + applianceHost() + "/api/alive", proto + "//" + applianceHost() + "/"];
    if (ip) probes.push(proto + "//" + ip + "/api/alive");
    var tick = 0;
    var timedOut = false;
    var maxWait = opts.maxWait || 20;
    var minTick = opts.minTick || 4;
    var iv = setInterval(function () {
      if (navigated) {
        clearInterval(iv);
        return;
      }
      tick += 1;
      var msg = progress + "… " + tick + "s";
      setWaitProgress(Math.min(95, Math.round((tick / maxWait) * 100)), msg);
      if ($("restartState")) $("restartState").textContent = msg;
      if (tick >= maxWait && !timedOut) {
        /* C8: do not jump to an unreachable page — offer the link and keep
           probing; the page still opens by itself once the router answers. */
        timedOut = true;
        clearInterval(iv);
        if ($("restartState")) {
          $("restartState").textContent = "Still waiting — reconnect to the router's network, then use the link below.";
          $("restartState").className = "state busy";
        }
        if ($("restartCopy")) {
          var c = $("restartCopy");
          c.textContent = (opts.copy ? opts.copy + " " : "") + "If this page does not move on, ";
          var a = document.createElement("a");
          a.href = resumeName;
          a.textContent = "open the next screen";
          c.appendChild(a);
          c.appendChild(document.createTextNode("."));
        }
      }
    }, 1000);
    function ping(i) {
      if (navigated) return;
      var u = probes[i % probes.length];
      probeUrl(u, "no-cors", 2500).then(function (ok) {
        if (navigated) return;
        if (ok && tick >= minTick) {
          clearInterval(iv);
          go();
          return;
        }
        setTimeout(function () {
          ping(i + 1);
        }, timedOut ? 3000 : 400);
      });
    }
    setTimeout(function () {
      ping(0);
    }, opts.probeDelay || 3000);
  }

  function showFinishWait(opts) {
    opts = opts || {};
    var ssid = String(opts.ssid || "");
    var lanMoved = !!opts.lanMoved;
    var dest = safeDest(opts.dest || nodeStatusUrl("/"));
    var copy = "The router is applying your settings now.";
    if (ssid) {
      copy +=
        " Join Wi‑Fi “" +
        ssid +
        "” with the password you chose. Turn Wi‑Fi off and on if it does not reconnect. Stay on this network — do not join another saved Wi‑Fi.";
    }
    if (lanMoved) {
      copy +=
        " Your computer will get a new address. If you are on Wi‑Fi, turn it off and on. If you use a cable, unplug it and plug it back in.";
    }
    copy += " This page opens the next screen when the router is ready.";
    showSetupWait({
      title: "Applying your settings",
      copy: copy,
      progress: ssid ? "Waiting for " + ssid : "Waiting for the router",
      progressLabel: "Applying settings",
      resumeName: dest,
      lanIp: opts.lanIp || "",
      maxWait: 180,
      minTick: 8,
      probeDelay: 4000
    });
  }

  $("btnLan").onclick = function () {
    var ip = ($("lanIp").value || "").trim();
    $("btnLan").disabled = true;
    api("lan", {
      body: formBody({
        ipaddr: ip,
        netmask: ($("lanMask").value || "").trim(),
        dhcp_start: String($("lanDhcpStart").value || "100"),
        dhcp_limit: String($("lanDhcpLimit").value || "101")
      })
    })
      .then(function (d) {
        $("btnLan").disabled = false;
        if (!d.ok) {
          banner(d.message || d.error, true);
          return;
        }
        banner(d.message || "LAN saved. It applies when you finish Setup.", false);
        api("status").then(enterWifi).catch(function () {
          enterWifi({ wifi_available: true });
        });
      })
      .catch(function (e) {
        $("btnLan").disabled = false;
        banner(String(e.message || e), true);
      });
  };
  $("btnLanContinue").onclick = function () {
    api("status").then(enterWifi).catch(function () {
      enterWifi({ wifi_available: true });
    });
  };

  $("btnDone").onclick = function () {
    $("btnDone").disabled = true;
    api("complete", { method: "POST", body: "" })
      .then(function (d) {
        if (!d.ok) {
          $("btnDone").disabled = false;
          banner(d.message || d.error, true);
          return;
        }
        followLan(d);
        if (d.wifi_reconnect || d.lan_moved) {
          showFinishWait({
            ssid: d.ssid || "rnode",
            lanMoved: !!d.lan_moved,
            lanIp: d.lan_ip,
            dest: nodeStatusUrl(d.redirect)
          });
          return;
        }
        location.href = nodeStatusUrl(d.redirect);
      })
      .catch(function (e) {
        $("btnDone").disabled = false;
        banner(String(e.message || e), true);
      });
  };

  /* P1 (review 2026-10-10): labelled units broadcast Wi-Fi rnode with the
     per-device password on the label; unlabelled units keep Wi-Fi off until
     Setup, so Welcome must tell the user to use a LAN cable instead. The
     secret itself is never sent to the browser — only this flag. */
  function applyLabelled(st) {
    var noWifi = !!(st && st.factory_labelled === false);
    [["welcomeBody", "welcomeBodyNoWifi"], ["welcomeJoin", "welcomeJoinNoWifi"]].forEach(function (p) {
      var a = $(p[0]);
      var b = $(p[1]);
      if (a) a.hidden = noWifi;
      if (b) b.hidden = !noWifi;
    });
  }

  /* If already complete, go to Status */
  var boot = Promise.resolve();
  if (window.KnotsI18n) boot = window.KnotsI18n.detectInitial();
  boot
    .then(function () {
      return api("status");
    })
    .then(function (st) {
      if (st.complete) {
        location.href = nodeStatusUrl("/");
        return;
      }
      /* IUE: keep "Bitcoin Node" until the operator chooses Knots/Core on the Node step */
      if (window.KnotsBrand) window.KnotsBrand.apply("node");
      applyLabelled(st);
      /* Cert installed: HTTPS page loaded, or installer/soft-reload set after_tls.
         sessionStorage alone is leftover from a previous IUE (factory reset /
         sysupgrade -n) and must not skip Welcome on HTTP. */
      var afterTls =
        /(?:\?|&)after_tls=1\b/.test(location.search || "") ||
        location.protocol === "https:";
      var go = function () {
        var stepQ = /(?:\?|&)step=(\d+)\b/.exec(location.search || "");
        if (stepQ) {
          var resumeStep = parseInt(stepQ[1], 10);
          if (resumeStep === 0) {
            try {
              sessionStorage.removeItem("knots_tls_continue");
              sessionStorage.removeItem("knots_tls_reloaded");
            } catch (e0) {}
            /* step=0 is Welcome only on HTTP (reset / -n). After the CA is
               trusted, step=0 must not restart IUE — next page is Choice. */
            if (afterTls) {
              enterChoice();
              return;
            }
            welcomeUnlessMoved();
            return;
          }
          if (resumeStep === 1 && afterTls) {
            enterChoice();
            return;
          }
          if (resumeStep === 7) {
            enterWifi();
            return;
          }
          if (resumeStep >= 2 && resumeStep <= 9) {
            showStep(resumeStep);
            return;
          }
        }
        if (afterTls) {
          try {
            sessionStorage.removeItem("knots_tls_continue");
            sessionStorage.removeItem("knots_tls_reloaded");
          } catch (e2) {}
          enterChoice();
          return;
        }
        welcomeUnlessMoved();
      };
      if (st.lang && window.KnotsI18n) {
        return window.KnotsI18n.loadLang(st.lang).then(go);
      }
      go();
    })
    .catch(function () {
      welcomeUnlessMoved();
    });

  (function bindLuciLink() {
    var a = $("setupLuciLink");
    if (!a) return;
    a.href = "https://" + applianceHost() + ":8443/cgi-bin/luci/";
  })();

  bindPasswordReveals();
  bindPasswordMatch("pw1", "pw2");
  bindPasswordMatch("wifiKey", "wifiKey2");
  bindPasswordMatch("quickPw1", "quickPw2");
  bindPasswordMatch("quickWifiKey", "quickWifiKey2");
  bindNeedValue("wifiSsid");
  bindNeedValue("wifiCountry");
  bindNeedValue("pppoeUser");
  bindNeedValue("pppoePass");
  bindNeedValue("quickPppoeUser");
  bindNeedValue("quickPppoePass");
})();
