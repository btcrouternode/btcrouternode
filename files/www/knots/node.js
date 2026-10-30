/* SPDX-License-Identifier: GPL-2.0-only */
(function () {
  var walletPresent = false;

  function $(id) {
    return document.getElementById(id);
  }

  function parseJsonResponse(r) {
    return r.text().then(function (t) {
      try {
        return JSON.parse(t);
      } catch (e) {
        throw new Error(
          "Node API returned non-JSON (HTTP " + r.status + "). Check /api/node CGI."
        );
      }
    });
  }

  function api(action, extra) {
    var q = "/api/node?action=" + encodeURIComponent(action);
    if (extra) q += "&" + extra;
    return fetch(q, { cache: "no-store" }).then(parseJsonResponse);
  }

  // U15 — mutations go POST form-style; router auth travels in the body
  function apiPost(action, body) {
    return fetch("/api/node?action=" + encodeURIComponent(action), {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body,
      cache: "no-store"
    }).then(parseJsonResponse);
  }

  // Memory-only credentials (same pattern as settings.js) — never persisted
  function authPair(userId, passId) {
    var user = ($(userId).value || "").trim();
    var pass = $(passId).value || "";
    if (!user || !pass) {
      banner("Router username and password required.", true);
      return null;
    }
    return { user: user, pass: pass };
  }

  function authQuery(auth) {
    return (
      "&user=" +
      encodeURIComponent(auth.user) +
      "&password=" +
      encodeURIComponent(auth.pass)
    );
  }

  function banner(msg, err) {
    var b = $("banner");
    if (!msg) {
      b.hidden = true;
      return;
    }
    b.hidden = false;
    b.textContent = msg;
    b.className = err ? "warn" : "muted";
  }

  function needWalletAck() {
    return walletPresent && (!$("walletAck") || !$("walletAck").checked);
  }

  function walletAckQuery() {
    return walletPresent ? "&wallet_ack=WALLET_ACK" : "";
  }

  function renderWalletWarn(d) {
    walletPresent = !!(d.wallet_present === true || d.wallet_present === "true");
    var box = $("walletWarn");
    var names = $("walletNames");
    if (!box) return;
    if (walletPresent) {
      box.hidden = false;
      names.textContent = d.wallets
        ? "Wallet(s) found: " + d.wallets
        : "A wallet directory is present on the shared datadir.";
    } else {
      box.hidden = true;
      if ($("walletAck")) $("walletAck").checked = false;
      names.textContent = "";
    }
  }

  function renderPrev(impl, d) {
    var block = d[impl] || {};
    var el = $(impl + "Prev");
    var btn = $("btnRollback" + (impl === "core" ? "Core" : "Knots"));
    if (!el || !btn) return;
    if (block.prev_available) {
      el.textContent = block.prev_version || "available";
      btn.disabled = false;
    } else {
      el.textContent = "none";
      btn.disabled = true;
    }
  }

  function render(d) {
    var act = d.active || "knots";
    $("active").textContent = act === "core" ? "Bitcoin Core" : "Bitcoin Knots";
    if ($("factoryDefault")) {
      $("factoryDefault").textContent =
        (d.default || "knots") === "core" ? "Bitcoin Core" : "Bitcoin Knots";
    }
    $("knotsVer").textContent = d.knots && d.knots.installed ? d.knots.version : "not installed";
    $("coreVer").textContent = d.core && d.core.installed ? d.core.version : "not installed";
    $("running").textContent = d.running
      ? "Yes (" + (act === "core" ? "Core" : "Knots") + ")"
      : "No";
    if (act === "core") $("rCore").checked = true;
    else $("rKnots").checked = true;
    $("rCore").disabled = !(d.core && d.core.installed);
    renderWalletWarn(d);
    renderPrev("knots", d);
    renderPrev("core", d);
    if (!walletPresent) {
      banner(
        "Active implementation follows the M.2 preference (" +
          (act === "core" ? "Core" : "Knots") +
          "). Factory default remains Knots until you switch.",
        false
      );
    }
    if (window.KnotsBrand) window.KnotsBrand.apply(act);
  }

  function refreshApplianceBuild() {
    return fetch("/api/status", { cache: "no-store" })
      .then(function (r) {
        return r.json();
      })
      .then(function (d) {
        var el = $("applianceVer");
        if (el) {
          var ver = d.product_version || "—";
          var bn = d.build_number || "";
          el.textContent = bn ? ver + " · rev " + bn : ver;
        }
        if (window.KnotsBrand && window.KnotsBrand.applyBuild) {
          window.KnotsBrand.applyBuild(d.product_version, d.build_number);
        }
      })
      .catch(function () {});
  }

  function refresh() {
    return api("status")
      .then(function (d) {
        if (!d.ok) {
          banner(d.message || d.error || "Status failed", true);
          return;
        }
        render(d);
        return refreshApplianceBuild();
      })
      .catch(function (e) {
        banner(String(e), true);
      });
  }

  /* L2/L3 — switch / install / rollback run detached on the router; wait
     for its own verdict (status.last_op) instead of guessing from "active". */
  function pollOp(op, done) {
    var start = Date.now();
    function again() {
      return api("status").then(function (st) {
        var r = st && st.last_op;
        if (r && r.op === op && r.state && r.state !== "running") {
          render(st);
          banner(r.message || (r.state === "ok" ? "Done." : "Failed."), r.state !== "ok");
          if (done) done(r.state === "ok");
          return;
        }
        if (Date.now() - start > 900000) {
          banner("This is taking longer than expected — check Node Status.", true);
          if (done) done(false);
          return refresh();
        }
        return new Promise(function (res) {
          setTimeout(function () {
            res(again());
          }, 3000);
        });
      });
    }
    return again();
  }

  function confirmPopup(title, lines) {
    return window.confirm([title, ""].concat(lines).join("\n"));
  }

  $("btnApply").onclick = function () {
    var impl = $("rCore").checked ? "core" : "knots";
    var confirmTok = ($("confirm").value || "").trim();
    var auth = authPair("authUser", "authPass");
    if (!auth) return;
    if (confirmTok !== "SWITCH") {
      banner("Type SWITCH to confirm.", true);
      return;
    }
    if (needWalletAck()) {
      banner("Acknowledge the wallet backup warning before switching.", true);
      return;
    }
    if (
      !confirmPopup("Switch node software to " + impl + "?", [
        "The blockchain on the M.2 is kept (not wiped).",
        "Wallet files are intended to be the same keys under Knots or Core."
      ])
    ) {
      banner("Switch cancelled.", false);
      return;
    }
    $("btnApply").disabled = true;
    banner(
      "Node switch in progress — wait until this finishes. " +
        "Node Status will show the same message (not an RPC error).",
      false
    );
    var body =
      "impl=" +
      encodeURIComponent(impl) +
      "&confirm=" +
      encodeURIComponent(confirmTok) +
      walletAckQuery() +
      authQuery(auth);
    apiPost("set", body)
      .then(function (d) {
        if (!d.ok) {
          $("btnApply").disabled = false;
          banner(d.message || d.error || "Switch failed", true);
          return;
        }
        $("confirm").value = "";
        $("authPass").value = "";
        if ($("walletAck")) $("walletAck").checked = false;
        banner(d.message || "Switch started…", false);
        return pollOp("set", function () {
          $("btnApply").disabled = false;
        });
      })
      .catch(function (e) {
        $("btnApply").disabled = false;
        banner(String(e), true);
      });
  };

  $("btnInstall").onclick = function () {
    var impl = $("installImpl").value;
    var fileInput = $("tarball");
    var file = fileInput && fileInput.files && fileInput.files[0];
    var confirmTok = ($("confirmInstall").value || "").trim();
    var sha = ($("sha256").value || "").trim();
    var auth = authPair("authUser", "authPass");
    if (!auth) return;
    if (!file) {
      banner("Choose an official aarch64 .tar.gz first.", true);
      return;
    }
    if (confirmTok !== "INSTALL") {
      banner("Type INSTALL to confirm.", true);
      return;
    }
    if (needWalletAck()) {
      banner("Acknowledge the wallet backup warning before installing.", true);
      return;
    }
    if (!/aarch64/i.test(file.name)) {
      banner("Filename should contain aarch64 (official linux-gnu build).", true);
      return;
    }
    if (
      !confirmPopup("Install " + impl + " from " + file.name + "?", [
        "Previous binaries (if any) are kept for rollback.",
        "The blockchain is not wiped.",
        "If this implementation is active, the node will restart."
      ])
    ) {
      banner("Install cancelled.", false);
      return;
    }
    $("btnInstall").disabled = true;
    $("installHint").textContent = "Uploading " + file.name + " (" + Math.round(file.size / 1048576) + " MiB)…";
    banner("Installing " + impl + " — this can take a few minutes…", false);
    var q =
      "/api/node?action=install&impl=" +
      encodeURIComponent(impl) +
      "&confirm=INSTALL" +
      walletAckQuery();
    if (sha) q += "&sha256=" + encodeURIComponent(sha);
    // C3 — server stages the body under the (sanitized) original file name so
    // the aarch64 basename gate in node-impl.sh can pass; body stays the raw tarball
    q += "&name=" + encodeURIComponent(file.name);
    /* S5 — body is the raw tarball; credentials go in a header, not the URL. */
    fetch(q, {
      method: "POST",
      cache: "no-store",
      headers: {
        "Content-Type": "application/gzip",
        Authorization: "KnotsForm" + authQuery(auth).replace(/^&/, " ")
      },
      body: file
    })
      .then(parseJsonResponse)
      .then(function (d) {
        $("installHint").textContent = "";
        if (!d.ok) {
          $("btnInstall").disabled = false;
          banner(d.message || d.error || "Install failed", true);
          return;
        }
        $("confirmInstall").value = "";
        $("sha256").value = "";
        $("authPass").value = "";
        if (fileInput) fileInput.value = "";
        if ($("walletAck")) $("walletAck").checked = false;
        banner(d.message || "Installing…", false);
        return pollOp("install", function () {
          $("btnInstall").disabled = false;
        });
      })
      .catch(function (e) {
        $("btnInstall").disabled = false;
        $("installHint").textContent = "";
        banner(String(e), true);
      });
  };

  function doRollback(impl) {
    var confirmTok = ($("confirmRollback").value || "").trim();
    var auth = authPair("authUser", "authPass");
    if (!auth) return;
    if (confirmTok !== "ROLLBACK") {
      banner("Type ROLLBACK to confirm.", true);
      return;
    }
    if (needWalletAck()) {
      banner("Acknowledge the wallet backup warning before rollback.", true);
      return;
    }
    if (
      !confirmPopup("Rollback " + impl + " to the previous install?", [
        "The blockchain is not wiped.",
        "If this implementation is active, the node will restart."
      ])
    ) {
      banner("Rollback cancelled.", false);
      return;
    }
    var btn = $("btnRollback" + (impl === "core" ? "Core" : "Knots"));
    if (btn) btn.disabled = true;
    banner("Rolling back " + impl + "…", false);
    var body =
      "impl=" +
      encodeURIComponent(impl) +
      "&confirm=ROLLBACK" +
      walletAckQuery() +
      authQuery(auth);
    apiPost("rollback", body)
      .then(function (d) {
        if (!d.ok) {
          if (btn) btn.disabled = false;
          banner(d.message || d.error || "Rollback failed", true);
          return;
        }
        $("confirmRollback").value = "";
        $("authPass").value = "";
        if ($("walletAck")) $("walletAck").checked = false;
        banner(d.message || "Rolling back…", false);
        return pollOp("rollback", function () {
          if (btn) btn.disabled = false;
        });
      })
      .catch(function (e) {
        if (btn) btn.disabled = false;
        banner(String(e), true);
      });
  }

  $("btnRollbackKnots").onclick = function () {
    doRollback("knots");
  };
  $("btnRollbackCore").onclick = function () {
    doRollback("core");
  };

  refresh();
  setInterval(refresh, 20000);
})();
