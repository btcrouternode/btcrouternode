/* SPDX-License-Identifier: GPL-2.0-only */
(function () {
  function $(id) {
    return document.getElementById(id);
  }

  function banner(msg, isErr) {
    var el = $("banner");
    if (!el) return;
    el.hidden = !msg;
    el.textContent = msg || "";
    el.className = isErr ? "error" : "";
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

  function setFactoryResetProgress(visible, label, pct, detail, indeterminate) {
    var box = $("factoryResetProgress");
    var fill = $("factoryResetProgressFill");
    var bar = $("factoryResetProgressBar");
    if (!box || !fill) return;
    box.hidden = !visible;
    if ($("factoryResetProgressLabel")) {
      $("factoryResetProgressLabel").textContent =
        label || "Router Resetting to Factory Defaults";
    }
    if ($("factoryResetProgressDetail")) {
      $("factoryResetProgressDetail").textContent = detail || "";
    }
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
        "Settings API returned non-JSON (HTTP " + r.status + "). " + (t || "").slice(0, 160)
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
        if ($("nodeRunning")) {
          $("nodeRunning").textContent =
            d.node_running === true ? "running" : d.node_running === false ? "stopped" : "—";
        }
        syncNodeCtlButtons(d.node_running, d.reindex_running);
        /* L1 — node_running flips before a restart/stop worker finishes;
           wait for node_busy to clear so the next action is not refused
           (node_busy) or raced. */
        /* L2 — the worker's own verdict (last_op) ends the wait too: a
           failed stop/start/restart no longer looks like success. */
        var op = d && d.last_op;
        var finished = op && op.state && op.state !== "running";
        if (!d.node_busy && (pred(d) || (finished && op.state === "failed"))) {
          if (finished) banner(op.message || (op.state === "failed" ? "Operation failed" : "Done."), op.state === "failed");
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
        if ($("caRestricted")) {
          /* P3/P4: old units keep an unrestricted CA until Renew / factory reset;
             the new installers refuse it, so say what to do. */
          $("caRestricted").textContent =
            d.ca_constrained === true
              ? "Restricted to this router."
              : d.ca_constrained === false
              ? "Not restricted (older certificate) — renew it so new devices can install it."
              : "";
        }
        if ($("nodeRunning")) {
          $("nodeRunning").textContent =
            d.node_running === true ? "running" : d.node_running === false ? "stopped" : "—";
        }
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
        if (!d || !d.ok) throw new Error((d && d.message) || "conf load failed");
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
    var title =
      typeof tls.isUbuntu === "function" && tls.isUbuntu()
        ? "Ubuntu will turn Ethernet off"
        : "Linux will turn Ethernet off";
    var lines =
      typeof tls.lanDropConfirmLines === "function"
        ? tls.lanDropConfirmLines()
        : [
            "Your computer may show Ethernet as disconnected while the router restarts.",
            "Leave the cable plugged in. Click LAN back on if Ubuntu turns it off.",
            "Keep the progress tab open. Do not power-cycle the router."
          ];
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
        keep ? "Keep existing router settings" : "Reset router settings to factory defaults"
      );
    }
    if (hint) {
      hint.textContent = keep
        ? "Keep Wi‑Fi, admin password, and network settings. First-run Setup will not run again."
        : "Wi‑Fi, admin password, and network settings return to factory defaults. First-run Setup runs again. Blockchain on M.2 is still not wiped.";
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
      banner("Router username and password required.", true);
      return null;
    }
    return { user: user, pass: pass };
  }

  function powerPost(action, confirmToken, confirmId, title, lines, userId, passId, extraBody) {
    var auth = authPair(userId, passId);
    if (!auth) return;
    var typed = ($(confirmId).value || "").trim();
    if (typed !== confirmToken) {
      banner("Type " + confirmToken + " to confirm.", true);
      return;
    }
    if (!confirmPopup(title, lines)) return;
    banner("Working…", false);
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
          banner((d && d.message) || (d && d.error) || "Action failed", true);
          return;
        }
        banner(d.message || "Done.", false);
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
          if ($("nodeRunning")) $("nodeRunning").textContent = "stopping…";
          return;
        }
        if (action === "node_stop") {
          if ($("nodeRunning")) $("nodeRunning").textContent = "stopping…";
          return pollNodeUntil(function (st) {
            return st && st.node_running === false;
          });
        }
        if (action === "node_start") {
          if ($("nodeRunning")) $("nodeRunning").textContent = "starting…";
          return pollNodeUntil(function (st) {
            return st && (st.node_running === true || st.reindex_running === true);
          });
        }
        load();
      })
      .catch(function (e) {
        if (action === "reboot" || action === "shutdown") {
          banner("Router is rebooting or shutting down…", false);
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
        "Stop the Bitcoin node?",
        ["bitcoind will stop. Chain data on the M.2 is kept.", "Use Start node when you want it running again."],
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
        banner(
          "Stop the Bitcoin node first. Start is only available when the node is stopped.",
          true
        );
        return;
      }
      var reindex = !!($("startReindex") && $("startReindex").checked);
      var kind =
        ($("startReindexKind") && $("startReindexKind").value) || "chainstate";
      if (kind !== "full") kind = "chainstate";
      var lines = ["bitcoind will start using the existing M.2 datadir."];
      var title = "Start the Bitcoin node?";
      if (reindex && kind === "full") {
        title = "Start the Bitcoin node with a full reindex?";
        lines.push(
          "You chose: Also rebuild the block index.",
          "This rebuilds the block index and the chain database from every block file already on the M.2. It is not downloading the blockchain again.",
          "This is slower than Repair chain database. Keep power on; it can take many hours."
        );
      } else if (reindex) {
        title = "Start the Bitcoin node with reindex?";
        lines.push(
          "You chose: Repair chain database (usual).",
          "This validates the chain database from blocks already on the M.2. It is not downloading the blockchain again.",
          "Keep power on; this can take many hours."
        );
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
        "Reboot the appliance?",
        ["The Bitcoin node will be stopped first.", "The router will reboot. LAN briefly drops."],
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
        "Replace the HTTPS certificate?",
        [
          "A new certificate is created for this router.",
          "Every device must install it again before secure pages work there."
        ],
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
        "Shut down the appliance?",
        [
          "The Bitcoin node will be stopped first.",
          "The router will power off. You must power it on again manually."
        ],
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
        banner("Router username and password required.", true);
        return;
      }
      if (conf !== "RESET") {
        banner("Type RESET to confirm.", true);
        return;
      }
      if (
        !confirmPopup("Reset to factory defaults?", [
          "Router settings return to the appliance baseline.",
          "Admin password becomes the factory default again.",
          "You will go through first-run Setup (IUE) again.",
          "The blockchain on the M.2 is NOT wiped."
        ])
      ) {
        return;
      }
      if (!maybeLanDropPopup()) return;
      banner("Starting factory reset…", false);
      setFactoryResetProgress(
        true,
        "Router Resetting to Factory Defaults",
        0,
        "Opening reset page…",
        true
      );
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
            banner((d && d.message) || (d && d.error) || "Factory reset failed", true);
            setFactoryResetProgress(false, "", 0, "", false);
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
    wrap.innerHTML =
      '<label>SHA256 checksum (required)' +
      '<input id="upgradeSha256" type="text" autocomplete="off" spellcheck="false" ' +
      'placeholder="Paste 64-character hex from the release page" /></label>';
    var hint = document.createElement("p");
    hint.className = "muted";
    hint.textContent =
      "Copy the hash from the release / checksum page (or the .sha256 file). Required before upgrade.";
    if (anchor.nextSibling) {
      anchor.parentNode.insertBefore(wrap, anchor.nextSibling);
      anchor.parentNode.insertBefore(hint, wrap.nextSibling);
    } else {
      anchor.parentNode.appendChild(wrap);
      anchor.parentNode.appendChild(hint);
    }
    var btn = $("btnUpgrade");
    if (btn) btn.textContent = "Verify & upgrade";
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
      banner("Choose a sysupgrade image file.", true);
      return;
    }
    var fname = file.name || "";
    if (/sdcard|\.img\.gz$/i.test(fname)) {
      banner(
        "SD card images (*.img.gz) cannot be used here. Choose a *sysupgrade.itb file (Settings upgrade).",
        true
      );
      return;
    }
    if (fname && !/sysupgrade\.(itb|bin)$/i.test(fname)) {
      banner("Expected a filename ending in sysupgrade.itb (or .bin).", true);
      return;
    }
    if (!expectSha) {
      banner(
        "Paste the SHA256 from the release / checksum page (64 hex characters).",
        true
      );
      return;
    }
    if (conf !== "UPGRADE") {
      banner("Type UPGRADE to confirm.", true);
      return;
    }
    if (!user || !pass) {
      banner("Router username and password required.", true);
      return;
    }
    var keepConfig = upgradeKeepConfig();
    var confirmLines = [
      "File: " + file.name,
      "Size: " + fmtBytes(file.size),
      "SHA256: " + expectSha.slice(0, 12) + "…" + expectSha.slice(-8),
      keepConfig
        ? "Router settings: KEEP (Wi‑Fi, password, network)."
        : "Router settings: RESET to factory defaults (Setup will run again).",
      "The blockchain on the M.2 will NOT be wiped.",
      "The device will reboot."
    ];
    if (
      !confirmPopup(
        keepConfig ? "Upgrade appliance software?" : "Upgrade and reset router settings?",
        confirmLines
      )
    ) {
      return;
    }
    if (!maybeLanDropPopup()) return;

    var prevVersion = ($("productVer") && $("productVer").textContent) || "";
    btn.disabled = true;
    banner("Preparing upgrade…", false);
    setUpgradeProgress(
      true,
      "Preparing…",
      0,
      file.name + " (" + fmtBytes(file.size) + ")",
      true
    );

    function startUpload(localOk) {
      banner(
        localOk
          ? "Local checksum OK — uploading… keep this page open."
          : "Uploading — router will verify SHA256 before flash (normal on HTTP).",
        false
      );
      setUpgradeProgress(
        true,
        "Uploading image…",
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
          "Firmware Update in Progress",
          100,
          why || "Opening firmware update page…",
          true
        );
        banner("Firmware upgrade started — opening progress page…", false);
        goUpgradePage(prevVersion, expectedSeconds || 180, keepConfig);
      }

      xhr.upload.onprogress = function (ev) {
        if (!ev.lengthComputable) {
          setUpgradeProgress(
            true,
            "Uploading image…",
            0,
            fmtBytes(ev.loaded) + " sent",
            true
          );
          return;
        }
        var pct = (ev.loaded / ev.total) * 100;
        setUpgradeProgress(
          true,
          "Uploading image… " + Math.round(pct) + "%",
          pct,
          fmtBytes(ev.loaded) + " / " + fmtBytes(ev.total),
          false
        );
      };

      xhr.upload.onload = function () {
        uploadFinished = true;
        setUpgradeProgress(
          true,
          "Processing on router…",
          100,
          "Verifying SHA256 on appliance, then sysupgrade",
          true
        );
        banner("Upload finished — router is verifying checksum…", false);
      };

      xhr.onerror = function () {
        if (uploadFinished) {
          enterRebootWait("Link dropped after upload — waiting for reboot");
          return;
        }
        btn.disabled = false;
        setUpgradeProgress(true, "Upload failed", 0, "Network error during upload", false);
        banner("Upload failed — network error. Check LAN and try again.", true);
      };

      xhr.ontimeout = function () {
        if (uploadFinished) {
          enterRebootWait("Timed out waiting for upgrade response — waiting for reboot");
          return;
        }
        btn.disabled = false;
        setUpgradeProgress(true, "Timed out", 0, "Upload took too long", false);
        banner("Upload timed out. Try again on a stable LAN link.", true);
      };

      xhr.onload = function () {
        var d;
        try {
          d = parseJsonResponse(xhr, xhr.responseText || "");
        } catch (e) {
          if (uploadFinished || xhr.status === 0) {
            enterRebootWait("Router rebooting (response cut) — waiting to reconnect");
            return;
          }
          btn.disabled = false;
          setUpgradeProgress(true, "Upgrade failed", 0, String(e.message || e), false);
          banner(String(e.message || e), true);
          return;
        }
        if (!d || !d.ok) {
          btn.disabled = false;
          var msg = (d && d.message) || (d && d.error) || "Upgrade failed";
          setUpgradeProgress(true, "Upgrade rejected", 0, msg, false);
          banner(msg, true);
          return;
        }
        $("upgradeConfirm").value = "";
        $("upgradePass").value = "";
        enterRebootWait(
          (d.message || "Device will reboot") + (d.bytes ? " (" + fmtBytes(d.bytes) + ")" : ""),
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
              "Checksum mismatch",
              0,
              "File does not match the SHA256 you pasted",
              false
            );
            banner(
              "SHA256 mismatch — the file does not match the checksum. Re-download the image and paste the hash from the release page.",
              true
            );
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
      banner("Type SAVE to confirm.", true);
      return;
    }
    if (!user || !pass) {
      banner("Router username and password required.", true);
      return;
    }
    if (
      !confirmPopup("Save bitcoin.conf and restart the node?", [
        "Allowlisted settings only.",
        "bitcoind will restart. Chain data is kept."
      ])
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
    banner("Saving and restarting node…", false);
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
          banner((d && d.message) || (d && d.error) || "Save failed", true);
          return;
        }
        banner(d.message || "Saved.", false);
        $("confConfirm").value = "";
        $("confPass").value = "";
        if ($("nodeRunning")) $("nodeRunning").textContent = "restarting…";
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
      banner("Type ADVANCED for raw editor.", true);
      return;
    }
    if (conf !== "SAVE") {
      banner("Type SAVE to confirm.", true);
      return;
    }
    if (!user || !pass) {
      banner("Router username and password required.", true);
      return;
    }
    if (
      !confirmPopup("Save raw bitcoin.conf and restart the node?", [
        "Advanced path — product topology keys cannot change.",
        "bitcoind will restart. Chain data is kept."
      ])
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
    banner("Saving raw conf and restarting node…", false);
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
          banner((d && d.message) || (d && d.error) || "Save failed", true);
          return;
        }
        banner(d.message || "Saved.", false);
        $("advConfirm").value = "";
        $("advConfirmAdv").value = "";
        $("advPass").value = "";
        if ($("nodeRunning")) $("nodeRunning").textContent = "restarting…";
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
        banner("Router username and password required.", true);
        return;
      }
      if (!lang) {
        banner("Choose a language.", true);
        return;
      }
      if (typed !== "LANGUAGE") {
        banner("Type LANGUAGE to confirm.", true);
        return;
      }
      if (
        !confirmPopup("Change UI language?", [
          "Knots Node Status and LuCI will both use: " + lang,
          "Requires router root password (U15)."
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
      banner("Applying language…", false);
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
            banner((d && d.message) || (d && d.error) || "Language change failed", true);
            return;
          }
          if ($("langConfirm")) $("langConfirm").value = "";
          if ($("langPass")) $("langPass").value = "";
          banner(d.message || "Language updated.", false);
          /* Reload so Knots i18n + nav pick up /ui-lang */
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
  load();
})();
