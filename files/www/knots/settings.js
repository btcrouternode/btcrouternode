/* SPDX-License-Identifier: GPL-2.0-only */
(function () {
  /* i18n: every user-visible string is a catalogue key (settings.* for this
     page, api.settings.* for router answers); English ships in i18n/en.js. */
  function T(k, v) { return window.KnotsI18n ? window.KnotsI18n.t(k, v) : k; }

  function $(id) {
    return document.getElementById(id);
  }

  /* A banner drawn from a catalogue key is re-drawn when the language loads. */
  var bannerKey = null;

  function banner(msg, isErr) {
    var el = $("banner");
    bannerKey = null;
    if (!el) return;
    el.hidden = !msg;
    el.textContent = msg || "";
    el.className = isErr ? "error" : "";
  }

  function bannerT(key, vars, isErr) {
    banner(T(key, vars), isErr);
    bannerKey = { key: key, vars: vars, isErr: isErr };
  }

  /* Router answers carry English text and, on errors, a stable "error" code.
     Show the catalogue string for a known code or a known sentence; anything
     else falls back to the router's own text. */
  var API_ERROR_KEYS = {
    bad_length: "api.settings.bad_length",
    bad_size: "api.settings.bad_size",
    too_large: "api.settings.too_large",
    wan_denied: "api.settings.wan_denied",
    creds_in_url: "api.settings.creds_in_url",
    auth_locked: "api.settings.auth_locked",
    auth_failed: "api.settings.auth_failed",
    origin_denied: "api.settings.origin_denied",
    method: "api.settings.method",
    node_busy: "api.settings.node_busy",
    confirm_required: "api.settings.confirm_required",
    bad_lang: "api.settings.bad_lang",
    no_conf: "api.settings.no_conf",
    temp: "api.settings.temp",
    empty_conf: "api.settings.empty_conf",
    no_changes: "api.settings.no_changes",
    write_failed: "api.settings.write_failed",
    product_keys: "api.settings.product_keys",
    reindex_in_progress: "api.settings.reindex_in_progress",
    already_running: "api.settings.already_running",
    bad_sha256: "api.settings.bad_sha256",
    sha256_required: "api.settings.sha256_required",
    bad_filename: "api.settings.bad_filename",
    empty_upload: "api.settings.empty_upload",
    sha256_mismatch: "api.settings.sha256_mismatch",
    unsigned_image: "api.settings.unsigned_image",
    bad_signature: "api.settings.bad_signature",
    no_sysupgrade: "api.settings.no_sysupgrade",
    bad_action: "api.settings.bad_action"
  };

  /* Success answers and node-operation results (last_op) come as text only. */
  var API_TEXT_KEYS = {
    "UI language updated for Knots and LuCI.": "api.settings.lang_updated",
    "bitcoin.conf saved; node restarting.": "api.settings.conf_saved_restarting",
    "bitcoin.conf saved; node restarted.": "api.settings.conf_restarted",
    "bitcoin.conf saved; node restarted and is still loading.": "api.settings.conf_still_loading",
    "bitcoin.conf saved, but the node did not start again. Check the last change, or see the node log.":
      "api.settings.conf_not_started",
    "Bitcoin node stopping.": "api.settings.node_stopping",
    "Bitcoin node stopped.": "api.settings.node_stopped",
    "The Bitcoin node is still running after the stop request. Try again.": "api.settings.stop_failed",
    "Bitcoin node starting.": "api.settings.node_starting",
    "Bitcoin node starting with reindex. Keep power on — validation can take many hours. Not a blockchain re-download.":
      "api.settings.node_starting_reindex",
    "Bitcoin node starting with a full reindex. Keep power on — this can take many hours. Not a blockchain re-download.":
      "api.settings.node_starting_full",
    "Bitcoin node started.": "api.settings.node_started",
    "The Bitcoin node did not start — see the node log.": "api.settings.start_failed",
    "Reindex running — keep power on.": "api.settings.reindex_running",
    "Full reindex running — keep power on.": "api.settings.reindex_full_running",
    "The node did not start the reindex — see the node log.": "api.settings.reindex_not_started",
    "Stopping Bitcoin node and rebooting…": "api.settings.rebooting",
    "Stopping Bitcoin node and shutting down…": "api.settings.shutting_down",
    "Factory Reset in Progress": "api.settings.factory_reset_started",
    "New HTTPS certificate created. Install it again on each device (Install trust page) — the old one no longer works.":
      "api.settings.tls_renewed",
    "Checksum verified — upgrade starting (keeping router settings). Device will reboot. Blockchain on M.2 is not wiped.":
      "api.settings.upgrade_keep",
    "Checksum verified — upgrade starting (resetting router settings). Device will reboot. Blockchain on M.2 is not wiped.":
      "api.settings.upgrade_reset",
    "In progress": "settings.op.in_progress",
    "Done.": "settings.op.done"
  };

  function apiText(d, fallbackKey) {
    var code = (d && d.error) || "";
    var msg = (d && d.message) || "";
    var m;
    if (code === "conf_rejected") {
      /* bitcoin-conf-lib.sh conf_write_raw_validated */
      m = /^blocked_key:(.+)$/.exec(msg);
      if (m) return T("api.settings.blocked_key", { key: m[1] });
      if (msg === "missing_product_keys") return T("api.settings.missing_product_keys");
      return msg || T("api.settings.conf_rejected");
    }
    if (code === "bad_value") {
      m = /for (\S+)$/.exec(msg);
      if (m) return T("api.settings.bad_value", { key: m[1] });
    }
    if (code === "tls_failed") {
      m = /certificate: ([\s\S]*)$/.exec(msg);
      return T("api.settings.tls_failed", { detail: m ? m[1] : "" });
    }
    if (code && API_ERROR_KEYS[code]) return T(API_ERROR_KEYS[code]);
    if (msg && API_TEXT_KEYS[msg]) return T(API_TEXT_KEYS[msg]);
    if (/^The \S+ operation stopped unexpectedly/.test(msg)) return T("api.settings.op_interrupted");
    return msg || code || (fallbackKey ? T(fallbackKey) : "");
  }

  /* Node status word (running / stopped / stopping… ) — kept as a state so a
     language change re-draws it. */
  var NODE_STATE_KEYS = {
    running: "settings.node.state.running",
    stopped: "settings.node.state.stopped",
    stopping: "settings.node.state.stopping",
    starting: "settings.node.state.starting",
    restarting: "settings.node.state.restarting"
  };
  var nodeState = null;

  function setNodeState(st) {
    nodeState = NODE_STATE_KEYS[st] ? st : null;
    if ($("nodeRunning")) {
      $("nodeRunning").textContent = nodeState ? T(NODE_STATE_KEYS[nodeState]) : "—";
    }
  }

  function nodeStateFrom(d) {
    return d.node_running === true ? "running" : d.node_running === false ? "stopped" : null;
  }

  /* P3/P4: old units keep an unrestricted CA until Renew / factory reset;
     the new installers refuse it, so say what to do. */
  var caConstrained = null;

  function drawCaRestricted() {
    if (!$("caRestricted")) return;
    $("caRestricted").textContent =
      caConstrained === true
        ? T("settings.tls.restricted")
        : caConstrained === false
        ? T("settings.tls.unrestricted")
        : "";
  }

  /* "Type WORD to confirm": WORD is what the router checks, so it is never
     translated — only the sentence around it (data-confirm-i18n). */
  function drawConfirmLabels() {
    var els = document.querySelectorAll("[data-confirm]");
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      var word = el.getAttribute("data-confirm") || "";
      var tpl = T(el.getAttribute("data-confirm-i18n") || "settings.confirm.type", {
        word: "\u0000"
      });
      var parts = String(tpl).split("\u0000");
      if (parts.length < 2) continue; /* no usable string: keep the page text */
      el.textContent = "";
      el.appendChild(document.createTextNode(parts[0]));
      var strong = document.createElement("strong");
      strong.textContent = word;
      el.appendChild(strong);
      el.appendChild(document.createTextNode(parts.slice(1).join(word)));
    }
  }

  /* <title> is "Settings — <brand>"; shell.js owns the brand part. */
  function drawTitle() {
    var t = document.title || "";
    var i = t.indexOf(" — ");
    if (i >= 0) document.title = T("nav.settings") + t.slice(i);
  }

  function setUpgradeProgress(visible, label, pct, detail, indeterminate) {
    var box = $("upgradeProgress");
    var fill = $("upgradeProgressFill");
    var bar = $("upgradeProgressBar");
    if (!box || !fill) return;
    box.hidden = !visible;
    if ($("upgradeProgressLabel")) $("upgradeProgressLabel").textContent = label || "";
    if ($("upgradeProgressDetail")) $("upgradeProgressDetail").textContent = detail || "";
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

  /* H7: one builder (shell.js KnotsIue.destUrl); wait pages stay on HTTP. */
  function namedPage(path, query) {
    return window.KnotsIue.destUrl(path, query);
  }


  /* Hand off to dedicated /reset.html (full reset page + Setup when done). */
  function goFactoryResetPage(expectedSeconds) {
    var expectedMs = Math.max(60, Number(expectedSeconds) || 150) * 1000;
    window.location.replace(
      namedPage(
        "/reset.html",
        "go=1&sec=" + encodeURIComponent(String(Math.round(expectedMs / 1000))) + "&_=" + Date.now()
      )
    );
  }


  function fmtBytes(n) {
    if (n == null || isNaN(n)) return "—";
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(1) + " KiB";
    return (n / 1048576).toFixed(1) + " MiB";
  }

  function parseJsonResponse(r, t) {
    try {
      return JSON.parse(t);
    } catch (e) {
      throw new Error(
        T("settings.err.non_json", { status: r.status, text: (t || "").slice(0, 160) })
      );
    }
  }

  /* S5 — credentials for raw-body requests (image / raw conf) go in a header,
     never the URL: query strings end up in server logs and browser history.
     cgi-lib.sh auth_header_field parses this. */
  function knotsFormAuth(user, pass) {
    return (
      "KnotsForm user=" +
      encodeURIComponent(user) +
      "&password=" +
      encodeURIComponent(pass)
    );
  }

  function apiJson(url, opts) {
    return fetch(url, opts || { cache: "no-store" }).then(function (r) {
      return r.text().then(function (t) {
        return parseJsonResponse(r, t);
      });
    });
  }

  function pollNodeUntil(pred, ms) {
    var start = Date.now();
    ms = ms || 180000;
    function again() {
      return apiJson("/api/settings?action=status").then(function (d) {
        setNodeState(nodeStateFrom(d));
        syncNodeCtlButtons(d.node_running, d.reindex_running);
        /* L1 — node_running flips before a restart/stop worker finishes;
           wait for node_busy to clear so the next action is not refused
           (node_busy) or raced. */
        /* L2 — the worker's own verdict (last_op) ends the wait too: a
           failed stop/start/restart no longer looks like success. */
        var op = d && d.last_op;
        var finished = op && op.state && op.state !== "running";
        if (!d.node_busy && (pred(d) || (finished && op.state === "failed"))) {
          if (finished) {
            banner(
              apiText({ message: op.message }, op.state === "failed" ? "settings.op.failed" : "settings.op.done"),
              op.state === "failed"
            );
          }
          return d;
        }
        if (Date.now() - start > ms) return d;
        return new Promise(function (res) {
          setTimeout(function () {
            res(again());
          }, 2000);
        });
      });
    }
    return again();
  }

  function load() {
    return apiJson("/api/settings?action=status")
      .then(function (d) {
        if ($("productVer")) $("productVer").textContent = d.product_version || "—";
        /* N20: unique per-unit LAN name (works with several RNodes on one LAN) */
        if ($("unitName") && d.unit_name) {
          $("unitName").textContent = "https://" + d.unit_name + ".local/";
          if ($("unitNameBox")) $("unitNameBox").hidden = false;
        }
        /* "Add another computer": the plain address opens Enable Secure Connection */
        if ($("addPcUrl") && d.unit_name) $("addPcUrl").textContent = "http://" + d.unit_name + ".local";
        if ($("caFingerprint")) $("caFingerprint").textContent = d.ca_sha256 || "—";
        caConstrained = typeof d.ca_constrained === "boolean" ? d.ca_constrained : null;
        drawCaRestricted();
        setNodeState(nodeStateFrom(d));
        syncNodeCtlButtons(d.node_running, d.reindex_running);
        if (window.KnotsBrand) {
          window.KnotsBrand.applyBuild(d.product_version, null);
        }
        return fillLangSelect(d.lang || "en").then(function () {
          return d;
        });
      })
      .then(function () {
        return apiJson("/api/settings?action=conf");
      })
      .then(function (d) {
        if (!d || !d.ok) throw new Error(apiText(d, "settings.err.conf_load"));
        var s = d.safe || {};
        ["dbcache", "maxconnections", "maxmempool", "mempoolexpiry", "blocksonly", "peerbloomfilters"].forEach(
          function (k) {
            if ($(k) && s[k] != null) $(k).value = s[k];
          }
        );
        if ($("rawConf") && typeof d.raw === "string") {
          $("rawConf").value = d.raw.replace(/\\n/g, "\n");
        }
      })
      .catch(function (e) {
        banner(String(e.message || e), true);
      });
  }

  function fillLangSelect(current) {
    var sel = $("uiLang");
    if (!sel) return Promise.resolve();
    return fetch("/i18n/regions.json", { cache: "no-store" })
      .then(function (r) {
        return r.json();
      })
      .then(function (cat) {
        var langs = (cat && cat.languages) || [];
        sel.innerHTML = "";
        langs.forEach(function (L) {
          var opt = document.createElement("option");
          opt.value = L.id;
          opt.textContent = L.label || L.id;
          if (L.id === current) opt.selected = true;
          sel.appendChild(opt);
        });
        if (!sel.value && langs.length) sel.value = langs[0].id;
      })
      .catch(function () {
        /* keep empty — apply will fail closed */
      });
  }

  function confirmPopup(title, lines) {
    return window.confirm([title, ""].concat(lines).join("\n"));
  }

  /* Ubuntu/Linux NetworkManager drops Ethernet when the switch carrier goes
     away on reboot. Chrome often omits "Ubuntu" from the UA — treat Linux
     desktop the same. Other OSes keep the wait-page copy only. */
  function maybeLanDropPopup() {
    var tls = window.KnotsTlsOs;
    if (!tls || typeof tls.isLinuxDesktop !== "function" || !tls.isLinuxDesktop()) {
      return true;
    }
    var os = typeof tls.isUbuntu === "function" && tls.isUbuntu() ? "Ubuntu" : "Linux";
    var title = T("settings.landrop.title", { os: os });
    var lines =
      typeof tls.lanDropConfirmLines === "function"
        ? tls.lanDropConfirmLines()
        : [T("settings.landrop.body", { os: os })];
    return confirmPopup(title, lines);
  }

  /* Hand off to dedicated /upgrade.html (same UX as factory reset). */
  function goUpgradePage(prevVersion, expectedSeconds, keepConfig) {
    var expectedMs = Math.max(60, Number(expectedSeconds) || 180) * 1000;
    var prev = prevVersion || "";
    var keep = keepConfig !== false && keepConfig !== 0 && keepConfig !== "0";
    window.location.replace(
      namedPage(
        "/upgrade.html",
        "go=1&sec=" +
          encodeURIComponent(String(Math.round(expectedMs / 1000))) +
          "&prev=" +
          encodeURIComponent(prev) +
          "&keep=" +
          (keep ? "1" : "0") +
          "&_=" +
          Date.now()
      )
    );
  }


  function upgradeKeepConfig() {
    var btn = $("upgradeKeepToggle");
    if (!btn) return true;
    return btn.getAttribute("aria-checked") !== "false";
  }

  function syncUpgradeKeepUi() {
    var keep = upgradeKeepConfig();
    var hint = $("upgradeKeepHint");
    var keepLab = $("upgradeKeepLabel");
    var resetLab = $("upgradeResetLabel");
    var btn = $("upgradeKeepToggle");
    if (keepLab) keepLab.classList.toggle("is-active", keep);
    if (resetLab) resetLab.classList.toggle("is-active", !keep);
    if (btn) {
      btn.setAttribute(
        "aria-label",
        keep ? T("settings.upgrade.keep_aria") : T("settings.upgrade.reset_aria")
      );
    }
    if (hint) {
      hint.textContent = keep ? T("settings.upgrade.hint.keep") : T("settings.upgrade.hint.reset");
    }
  }

  function wireUpgradeKeepToggle() {
    var btn = $("upgradeKeepToggle");
    if (!btn) return;
    function setKeep(keep) {
      btn.setAttribute("aria-checked", keep ? "true" : "false");
      syncUpgradeKeepUi();
    }
    btn.addEventListener("click", function () {
      setKeep(!upgradeKeepConfig());
    });
    if ($("upgradeKeepLabel")) {
      $("upgradeKeepLabel").style.cursor = "pointer";
      $("upgradeKeepLabel").addEventListener("click", function () {
        setKeep(true);
      });
    }
    if ($("upgradeResetLabel")) {
      $("upgradeResetLabel").style.cursor = "pointer";
      $("upgradeResetLabel").addEventListener("click", function () {
        setKeep(false);
      });
    }
    syncUpgradeKeepUi();
  }

  wireUpgradeKeepToggle();

  function authPair(userId, passId) {
    var user = ($(userId).value || "").trim();
    var pass = $(passId).value || "";
    if (!user || !pass) {
      bannerT("settings.err.auth_required", null, true);
      return null;
    }
    return { user: user, pass: pass };
  }

  function powerPost(action, confirmToken, confirmId, title, lines, userId, passId, extraBody) {
    var auth = authPair(userId, passId);
    if (!auth) return;
    var typed = ($(confirmId).value || "").trim();
    if (typed !== confirmToken) {
      bannerT("settings.err.type_word", { word: confirmToken }, true);
      return;
    }
    if (!confirmPopup(title, lines)) return;
    bannerT("settings.working", null, false);
    var body =
      "action=" +
      encodeURIComponent(action) +
      "&confirm=" +
      encodeURIComponent(confirmToken) +
      "&user=" +
      encodeURIComponent(auth.user) +
      "&password=" +
      encodeURIComponent(auth.pass) +
      (extraBody || "");
    fetch("/api/settings?action=" + encodeURIComponent(action), {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body,
      cache: "no-store"
    })
      .then(function (r) {
        return r.text().then(function (t) {
          return parseJsonResponse(r, t);
        });
      })
      .then(function (d) {
        if (!d || !d.ok) {
          banner(apiText(d, "settings.err.action_failed"), true);
          return;
        }
        banner(apiText(d, "settings.op.done"), false);
        if ($(confirmId)) $(confirmId).value = "";
        if ($(passId)) $(passId).value = "";
        if (action === "node_start") {
          if ($("startReindex")) $("startReindex").checked = false;
          if ($("startReindexKind")) $("startReindexKind").value = "chainstate";
          syncStartReindexKind();
        }
        if (action === "tls_renew") {
          /* New CA: this page's own HTTPS trust is gone; go install the new one. */
          if (d.tls_url) {
            setTimeout(function () {
              location.href = "http://" + location.hostname + d.tls_url;
            }, 2500);
          }
          return;
        }
        if (action === "reboot" || action === "shutdown") {
          setNodeState("stopping");
          return;
        }
        if (action === "node_stop") {
          setNodeState("stopping");
          return pollNodeUntil(function (st) {
            return st && st.node_running === false;
          });
        }
        if (action === "node_start") {
          setNodeState("starting");
          return pollNodeUntil(function (st) {
            return st && (st.node_running === true || st.reindex_running === true);
          });
        }
        load();
      })
      .catch(function (e) {
        if (action === "reboot" || action === "shutdown") {
          bannerT("settings.power.going_down", null, false);
          return;
        }
        banner(String(e.message || e), true);
      });
  }

  if ($("btnStop")) {
    $("btnStop").addEventListener("click", function () {
      powerPost(
        "node_stop",
        "STOP",
        "stopConfirm",
        T("settings.node.stop.confirm_title"),
        [T("settings.node.stop.confirm_body")],
        "nodeUser",
        "nodePass"
      );
    });
  }
  var nodeIsStopped = false;
  function syncNodeCtlButtons(running, reindexRunning) {
    nodeIsStopped = running === false;
    var inReindex = reindexRunning === true;
    var canStart = nodeIsStopped && !inReindex;
    var canStop = running === true;
    var canReindex = canStart;
    if ($("btnStart")) $("btnStart").disabled = !canStart;
    if ($("startConfirm")) $("startConfirm").disabled = !canStart;
    if ($("startReindex")) $("startReindex").disabled = !canReindex;
    if ($("startReindexKind")) $("startReindexKind").disabled = !canReindex;
    if (!canReindex && $("startReindex")) {
      $("startReindex").checked = false;
      syncStartReindexKind();
    }
    if ($("startReindexProgress")) $("startReindexProgress").hidden = !inReindex;
    if ($("btnStop")) $("btnStop").disabled = !canStop;
    if ($("stopConfirm")) $("stopConfirm").disabled = !canStop;
  }
  function syncStartReindexKind() {
    var on = !!($("startReindex") && $("startReindex").checked);
    var wrap = $("startReindexKindWrap");
    if (wrap) wrap.hidden = !on;
  }
  if ($("startReindex")) {
    $("startReindex").addEventListener("change", syncStartReindexKind);
    syncStartReindexKind();
  }
  if ($("btnStart")) {
    $("btnStart").addEventListener("click", function () {
      if (!nodeIsStopped) {
        bannerT("settings.node.start.err_running", null, true);
        return;
      }
      var reindex = !!($("startReindex") && $("startReindex").checked);
      var kind =
        ($("startReindexKind") && $("startReindexKind").value) || "chainstate";
      if (kind !== "full") kind = "chainstate";
      var lines = [T("settings.node.start.confirm_body")];
      var title = T("settings.node.start.confirm_title");
      if (reindex && kind === "full") {
        title = T("settings.node.start.confirm_title_full");
        lines = [T("settings.node.start.confirm_body_full")];
      } else if (reindex) {
        title = T("settings.node.start.confirm_title_reindex");
        lines = [T("settings.node.start.confirm_body_reindex")];
      }
      powerPost(
        "node_start",
        "START",
        "startConfirm",
        title,
        lines,
        "nodeUser",
        "nodePass",
        reindex
          ? "&reindex=1&reindex_kind=" + encodeURIComponent(kind)
          : ""
      );
    });
  }
  if ($("btnReboot")) {
    $("btnReboot").addEventListener("click", function () {
      powerPost(
        "reboot",
        "REBOOT",
        "rebootConfirm",
        T("settings.reboot.confirm_title"),
        [T("settings.reboot.confirm_body")],
        "deviceUser",
        "devicePass"
      );
    });
  }
  if ($("btnTlsRenew")) {
    $("btnTlsRenew").addEventListener("click", function () {
      powerPost(
        "tls_renew",
        "RENEW",
        "tlsRenewConfirm",
        T("settings.tls.confirm_title"),
        [T("settings.tls.confirm_body")],
        "deviceUser",
        "devicePass"
      );
    });
  }
  if ($("btnShutdown")) {
    $("btnShutdown").addEventListener("click", function () {
      powerPost(
        "shutdown",
        "SHUTDOWN",
        "shutdownConfirm",
        T("settings.shutdown.confirm_title"),
        [T("settings.shutdown.confirm_body")],
        "deviceUser",
        "devicePass"
      );
    });
  }

  if ($("btnFactoryReset")) {
    $("btnFactoryReset").addEventListener("click", function () {
      var auth = {
        user: (($("resetUser") && $("resetUser").value) || "").trim(),
        pass: ($("resetPass") && $("resetPass").value) || ""
      };
      var conf = (($("resetConfirm") && $("resetConfirm").value) || "").trim();
      if (!auth.user || !auth.pass) {
        bannerT("settings.err.auth_required", null, true);
        return;
      }
      if (conf !== "RESET") {
        bannerT("settings.err.type_word", { word: "RESET" }, true);
        return;
      }
      if (
        !confirmPopup(T("settings.reset.confirm_title"), [T("settings.reset.confirm_body")])
      ) {
        return;
      }
      if (!maybeLanDropPopup()) return;
      bannerT("settings.reset.starting", null, false);
      var body =
        "action=factory_reset&confirm=RESET" +
        "&user=" +
        encodeURIComponent(auth.user) +
        "&password=" +
        encodeURIComponent(auth.pass);
      fetch("/api/settings?action=factory_reset", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: body,
        cache: "no-store"
      })
        .then(function (r) {
          return r.text().then(function (t) {
            return parseJsonResponse(r, t);
          });
        })
        .then(function (d) {
          if (!d || !d.ok) {
            banner(apiText(d, "settings.reset.failed"), true);
            return;
          }
          if ($("resetConfirm")) $("resetConfirm").value = "";
          if ($("resetPass")) $("resetPass").value = "";
          if ($("btnFactoryReset")) $("btnFactoryReset").disabled = true;
          goFactoryResetPage(d.expected_seconds || 650);
        })
        .catch(function () {
          /* Response often cuts when reset/reboot starts — still open reset page. */
          if ($("btnFactoryReset")) $("btnFactoryReset").disabled = true;
          goFactoryResetPage(650);
        });
    });
  }

  function normalizeSha256(raw) {
    var s = String(raw || "").trim();
    if (!s) return "";
    /* Accept "HASH  filename" lines from sha256sum / .sha256 files */
    s = s.split(/\s+/)[0];
    s = s.toLowerCase().replace(/^sha256:/, "");
    if (!/^[0-9a-f]{64}$/.test(s)) return "";
    return s;
  }

  /* If browser cached an older settings.html, inject the required SHA256 field. */
  function ensureUpgradeSha256Field() {
    if ($("upgradeSha256")) return;
    var fileInput = $("upgradeFile");
    if (!fileInput) return;
    var anchor = fileInput.closest("p") || fileInput.parentNode;
    if (!anchor || !anchor.parentNode) return;
    var wrap = document.createElement("p");
    var label = document.createElement("label");
    var labelText = document.createElement("span");
    labelText.textContent = T("settings.upgrade.sha_label");
    var input = document.createElement("input");
    input.id = "upgradeSha256";
    input.type = "text";
    input.setAttribute("autocomplete", "off");
    input.setAttribute("spellcheck", "false");
    input.placeholder = T("settings.upgrade.sha_placeholder");
    label.appendChild(labelText);
    label.appendChild(input);
    wrap.appendChild(label);
    var hint = document.createElement("p");
    hint.className = "muted";
    hint.textContent = T("settings.upgrade.sha_hint_short");
    if (anchor.nextSibling) {
      anchor.parentNode.insertBefore(wrap, anchor.nextSibling);
      anchor.parentNode.insertBefore(hint, wrap.nextSibling);
    } else {
      anchor.parentNode.appendChild(wrap);
      anchor.parentNode.appendChild(hint);
    }
    var btn = $("btnUpgrade");
    if (btn) btn.textContent = T("settings.upgrade.button");
  }

  ensureUpgradeSha256Field();

  function sha256FileHex(file) {
    /*
     * SubtleCrypto only exists in a secure context (HTTPS / localhost).
     * Firefox on http://192.168.x.x leaves crypto.subtle undefined — expected.
     * null → skip local hash; appliance sha256sum still gates sysupgrade (U13).
     */
    if (!window.isSecureContext || !window.crypto || !crypto.subtle || !crypto.subtle.digest) {
      return Promise.resolve(null);
    }
    return file.arrayBuffer().then(function (buf) {
      return crypto.subtle.digest("SHA-256", buf);
    }).then(function (digest) {
      var bytes = new Uint8Array(digest);
      var hex = "";
      for (var i = 0; i < bytes.length; i++) {
        hex += bytes[i].toString(16).padStart(2, "0");
      }
      return hex;
    });
  }

  $("btnUpgrade").addEventListener("click", function () {
    var file = $("upgradeFile").files && $("upgradeFile").files[0];
    var user = ($("upgradeUser").value || "").trim();
    var pass = $("upgradePass").value || "";
    var conf = ($("upgradeConfirm").value || "").trim();
    var expectSha = normalizeSha256($("upgradeSha256") && $("upgradeSha256").value);
    var btn = $("btnUpgrade");
    if (!file) {
      bannerT("settings.upgrade.err.no_file", null, true);
      return;
    }
    var fname = file.name || "";
    if (/sdcard|\.img\.gz$/i.test(fname)) {
      bannerT("settings.upgrade.err.sdcard", null, true);
      return;
    }
    if (fname && !/sysupgrade\.(itb|bin)$/i.test(fname)) {
      bannerT("settings.upgrade.err.filename", null, true);
      return;
    }
    if (!expectSha) {
      bannerT("settings.upgrade.err.no_sha", null, true);
      return;
    }
    if (conf !== "UPGRADE") {
      bannerT("settings.err.type_word", { word: "UPGRADE" }, true);
      return;
    }
    if (!user || !pass) {
      bannerT("settings.err.auth_required", null, true);
      return;
    }
    var keepConfig = upgradeKeepConfig();
    var confirmVars = {
      file: file.name,
      size: fmtBytes(file.size),
      sha: expectSha.slice(0, 12) + "…" + expectSha.slice(-8)
    };
    var confirmLines = [
      keepConfig
        ? T("settings.upgrade.confirm_body_keep", confirmVars)
        : T("settings.upgrade.confirm_body_reset", confirmVars)
    ];
    if (
      !confirmPopup(
        keepConfig ? T("settings.upgrade.confirm_title_keep") : T("settings.upgrade.confirm_title_reset"),
        confirmLines
      )
    ) {
      return;
    }
    if (!maybeLanDropPopup()) return;

    var prevVersion = ($("productVer") && $("productVer").textContent) || "";
    btn.disabled = true;
    bannerT("settings.upgrade.preparing_banner", null, false);
    setUpgradeProgress(
      true,
      T("settings.upgrade.p.preparing"),
      0,
      file.name + " (" + fmtBytes(file.size) + ")",
      true
    );

    function startUpload(localOk) {
      bannerT(localOk ? "settings.upgrade.uploading_ok" : "settings.upgrade.uploading_http", null, false);
      setUpgradeProgress(
        true,
        T("settings.upgrade.p.uploading"),
        0,
        file.name + " (" + fmtBytes(file.size) + ")",
        false
      );

      /*
       * The POST body is the raw image bytes (settings-api.sh reads stdin as the
       * image), so user/password travel in the Authorization header via
       * knotsFormAuth — never in the URL (S5).
       */
      var q =
        "/api/settings?action=upgrade&confirm=UPGRADE" +
        "&keep_config=" +
        (keepConfig ? "1" : "0") +
        "&filename=" +
        encodeURIComponent(file.name) +
        "&sha256=" +
        encodeURIComponent(expectSha);

      var xhr = new XMLHttpRequest();
      var uploadFinished = false;
      xhr.open("POST", q, true);
      xhr.responseType = "text";
      xhr.setRequestHeader("Content-Type", "application/octet-stream");
      xhr.setRequestHeader("Authorization", knotsFormAuth(user, pass));
      xhr.timeout = 900000;

      function enterRebootWait(why, expectedSeconds) {
        setUpgradeProgress(
          true,
          T("settings.upgrade.p.in_progress"),
          100,
          why || T("settings.upgrade.p.opening"),
          true
        );
        bannerT("settings.upgrade.started", null, false);
        goUpgradePage(prevVersion, expectedSeconds || 180, keepConfig);
      }

      xhr.upload.onprogress = function (ev) {
        if (!ev.lengthComputable) {
          setUpgradeProgress(
            true,
            T("settings.upgrade.p.uploading"),
            0,
            T("settings.upgrade.p.sent", { size: fmtBytes(ev.loaded) }),
            true
          );
          return;
        }
        var pct = (ev.loaded / ev.total) * 100;
        setUpgradeProgress(
          true,
          T("settings.upgrade.p.uploading_pct", { pct: Math.round(pct) }),
          pct,
          fmtBytes(ev.loaded) + " / " + fmtBytes(ev.total),
          false
        );
      };

      xhr.upload.onload = function () {
        uploadFinished = true;
        setUpgradeProgress(
          true,
          T("settings.upgrade.p.processing"),
          100,
          T("settings.upgrade.p.verifying"),
          true
        );
        bannerT("settings.upgrade.uploaded", null, false);
      };

      xhr.onerror = function () {
        if (uploadFinished) {
          enterRebootWait(T("settings.upgrade.link_dropped"));
          return;
        }
        btn.disabled = false;
        setUpgradeProgress(
          true,
          T("settings.upgrade.p.upload_failed"),
          0,
          T("settings.upgrade.p.network_error"),
          false
        );
        bannerT("settings.upgrade.err.network", null, true);
      };

      xhr.ontimeout = function () {
        if (uploadFinished) {
          enterRebootWait(T("settings.upgrade.timeout_wait"));
          return;
        }
        btn.disabled = false;
        setUpgradeProgress(
          true,
          T("settings.upgrade.p.timed_out"),
          0,
          T("settings.upgrade.p.too_long"),
          false
        );
        bannerT("settings.upgrade.err.timeout", null, true);
      };

      xhr.onload = function () {
        var d;
        try {
          d = parseJsonResponse(xhr, xhr.responseText || "");
        } catch (e) {
          if (uploadFinished || xhr.status === 0) {
            enterRebootWait(T("settings.upgrade.response_cut"));
            return;
          }
          btn.disabled = false;
          setUpgradeProgress(true, T("settings.upgrade.p.failed"), 0, String(e.message || e), false);
          banner(String(e.message || e), true);
          return;
        }
        if (!d || !d.ok) {
          btn.disabled = false;
          var msg = apiText(d, "settings.upgrade.p.failed");
          setUpgradeProgress(true, T("settings.upgrade.p.rejected"), 0, msg, false);
          banner(msg, true);
          return;
        }
        $("upgradeConfirm").value = "";
        $("upgradePass").value = "";
        enterRebootWait(
          apiText(d, "settings.upgrade.device_reboot") + (d.bytes ? " (" + fmtBytes(d.bytes) + ")" : ""),
          d.expected_seconds || 180
        );
      };

      xhr.send(file);
    }

    sha256FileHex(file)
      .then(function (got) {
        if (got) {
          if (got !== expectSha) {
            btn.disabled = false;
            setUpgradeProgress(
              true,
              T("settings.upgrade.p.mismatch"),
              0,
              T("settings.upgrade.p.mismatch_detail"),
              false
            );
            bannerT("settings.upgrade.err.mismatch", null, true);
            return;
          }
          startUpload(true);
          return;
        }
        startUpload(false);
      })
      .catch(function () {
        startUpload(false);
      });
  });

  $("btnSaveSafe").addEventListener("click", function () {
    var user = ($("confUser").value || "").trim();
    var pass = $("confPass").value || "";
    var conf = ($("confConfirm").value || "").trim();
    if (conf !== "SAVE") {
      bannerT("settings.err.type_word", { word: "SAVE" }, true);
      return;
    }
    if (!user || !pass) {
      bannerT("settings.err.auth_required", null, true);
      return;
    }
    if (
      !confirmPopup(T("settings.conf.confirm_title"), [T("settings.conf.confirm_body")])
    ) {
      return;
    }
    var body =
      "action=conf_save&confirm=SAVE" +
      "&user=" +
      encodeURIComponent(user) +
      "&password=" +
      encodeURIComponent(pass) +
      "&dbcache=" +
      encodeURIComponent($("dbcache").value) +
      "&maxconnections=" +
      encodeURIComponent($("maxconnections").value) +
      "&maxmempool=" +
      encodeURIComponent($("maxmempool").value) +
      "&mempoolexpiry=" +
      encodeURIComponent($("mempoolexpiry").value) +
      "&blocksonly=" +
      encodeURIComponent($("blocksonly").value) +
      "&peerbloomfilters=" +
      encodeURIComponent($("peerbloomfilters").value);
    bannerT("settings.conf.saving", null, false);
    fetch("/api/settings?action=conf_save", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body,
      cache: "no-store"
    })
      .then(function (r) {
        return r.text().then(function (t) {
          return parseJsonResponse(r, t);
        });
      })
      .then(function (d) {
        if (!d || !d.ok) {
          banner(apiText(d, "settings.conf.save_failed"), true);
          return;
        }
        banner(apiText(d, "settings.conf.saved"), false);
        $("confConfirm").value = "";
        $("confPass").value = "";
        setNodeState("restarting");
        return pollNodeUntil(function (st) {
          return st && st.node_running === true;
        }).then(function () {
          return load();
        });
      })
      .catch(function (e) {
        banner(String(e.message || e), true);
      });
  });

  $("btnSaveAdv").addEventListener("click", function () {
    var user = ($("advUser").value || "").trim();
    var pass = $("advPass").value || "";
    var conf = ($("advConfirm").value || "").trim();
    var adv = ($("advConfirmAdv").value || "").trim();
    if (adv !== "ADVANCED") {
      bannerT("settings.adv.err_type", { word: "ADVANCED" }, true);
      return;
    }
    if (conf !== "SAVE") {
      bannerT("settings.err.type_word", { word: "SAVE" }, true);
      return;
    }
    if (!user || !pass) {
      bannerT("settings.err.auth_required", null, true);
      return;
    }
    if (
      !confirmPopup(T("settings.adv.confirm_title"), [T("settings.adv.confirm_body")])
    ) {
      return;
    }
    /*
     * The POST body is the raw bitcoin.conf text (settings-api.sh reads stdin
     * as the conf), so user/password travel in the Authorization header via
     * knotsFormAuth — never in the URL (S5).
     */
    var q =
      "/api/settings?action=conf_save&advanced=1&confirm=SAVE&confirm_advanced=ADVANCED";
    bannerT("settings.adv.saving", null, false);
    fetch(q, {
      method: "POST",
      body: $("rawConf").value || "",
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        Authorization: knotsFormAuth(user, pass)
      },
      cache: "no-store"
    })
      .then(function (r) {
        return r.text().then(function (t) {
          return parseJsonResponse(r, t);
        });
      })
      .then(function (d) {
        if (!d || !d.ok) {
          banner(apiText(d, "settings.conf.save_failed"), true);
          return;
        }
        banner(apiText(d, "settings.conf.saved"), false);
        $("advConfirm").value = "";
        $("advConfirmAdv").value = "";
        $("advPass").value = "";
        setNodeState("restarting");
        return pollNodeUntil(function (st) {
          return st && st.node_running === true;
        }).then(function () {
          return load();
        });
      })
      .catch(function (e) {
        banner(String(e.message || e), true);
      });
  });

  if ($("btnLang")) {
    $("btnLang").addEventListener("click", function () {
      var user = ($("langUser").value || "").trim();
      var pass = $("langPass").value || "";
      var lang = ($("uiLang") && $("uiLang").value) || "";
      var typed = ($("langConfirm").value || "").trim();
      if (!user || !pass) {
        bannerT("settings.err.auth_required", null, true);
        return;
      }
      if (!lang) {
        bannerT("settings.lang.err_choose", null, true);
        return;
      }
      if (typed !== "LANGUAGE") {
        bannerT("settings.err.type_word", { word: "LANGUAGE" }, true);
        return;
      }
      var sel = $("uiLang");
      var langName =
        (sel && sel.selectedIndex >= 0 && sel.options[sel.selectedIndex].textContent) || lang;
      if (
        !confirmPopup(T("settings.lang.confirm_title"), [
          T("settings.lang.confirm_body", { lang: langName })
        ])
      ) {
        return;
      }
      var body =
        "action=locale&confirm=LANGUAGE&lang=" +
        encodeURIComponent(lang) +
        "&user=" +
        encodeURIComponent(user) +
        "&password=" +
        encodeURIComponent(pass);
      bannerT("settings.lang.applying", null, false);
      fetch("/api/settings?action=locale", {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: body,
        cache: "no-store"
      })
        .then(function (r) {
          return r.text().then(function (t) {
            return parseJsonResponse(r, t);
          });
        })
        .then(function (d) {
          if (!d || !d.ok) {
            banner(apiText(d, "settings.lang.failed"), true);
            return;
          }
          if ($("langConfirm")) $("langConfirm").value = "";
          if ($("langPass")) $("langPass").value = "";
          banner(apiText(d, "api.settings.lang_updated"), false);
          /* Reload so the page i18n + nav pick up /ui-lang */
          window.location.reload();
        })
        .catch(function (e) {
          banner(String(e.message || e), true);
        });
    });
  }

  /* H4 (review 2026-10-11): no sessionStorage resume here. Settings runs on
     https, the wait pages on http — a different origin — so the copy written
     here was never read by the wait page and only went stale (it drove a
     bogus resume later). The wait URL carries sec/prev/keep, and shell.js
     sends any page to the live wait page while an upgrade/reset runs. */
  try {
    /* Drop copies older builds left on this (https) origin. */
    sessionStorage.removeItem("knotsUpgradeWait");
    sessionStorage.removeItem("knotsFactoryResetWait");
  } catch (e) {
    /* private mode */
  }
  /* Re-draw the text this script draws once when a language loads. */
  function redraw() {
    drawTitle();
    drawConfirmLabels();
    setNodeState(nodeState);
    drawCaRestricted();
    syncUpgradeKeepUi();
    if (bannerKey) bannerT(bannerKey.key, bannerKey.vars, bannerKey.isErr);
  }
  if (window.KnotsI18n && typeof window.KnotsI18n.onChange === "function") {
    window.KnotsI18n.onChange(redraw);
  }
  drawConfirmLabels();
  load();
})();
