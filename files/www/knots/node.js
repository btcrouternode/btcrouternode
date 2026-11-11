/* SPDX-License-Identifier: GPL-2.0-only */
(function () {
  function T(k, v) { return window.KnotsI18n ? window.KnotsI18n.t(k, v) : k; }
  /* T(k) when the catalogue has k, else null (server text is the fallback). */
  function Tk(k, v) { var s = T(k, v); return s === k ? null : s; }

  var walletPresent = false;

  function implName(impl) {
    return impl === "core" ? "Bitcoin Core" : impl;
  }

  /* /api/node error reply → catalogue text by error code, else the router's text */
  function apiErr(d, fallbackKey) {
    var code = d && d.error;
    return (code && Tk("api.node." + code)) || (d && (d.message || d.error)) || T(fallbackKey);
  }

  /* Verdict of a detached install / rollback (status.last_op). The router's
     reason for a failure is technical English: shown after our own text. */
  function opVerdict(op, r) {
    if (r.state === "ok") return Tk("nodesw.op." + op + ".ok") || T("nodesw.op.done");
    var head = Tk("nodesw.op." + op + ".failed") || T("nodesw.op.failed");
    return r.message ? head + " " + T("nodesw.op.details", { text: r.message }) : head;
  }

  function $(id) {
    return document.getElementById(id);
  }

  function parseJsonResponse(r) {
    return r.text().then(function (t) {
      try {
        return JSON.parse(t);
      } catch (e) {
        throw new Error(T("nodesw.err.non_json", { status: r.status }));
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
      banner(T("nodesw.auth.required"), true);
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
        ? T("nodesw.wallet.found", { names: d.wallets })
        : T("nodesw.wallet.dir_present");
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
      el.textContent = block.prev_version || T("nodesw.rollback.available");
      btn.disabled = false;
    } else {
      el.textContent = T("nodesw.rollback.none");
      btn.disabled = true;
    }
  }

  /* Bitcoin Core is the only node software since build 120 (Knots dropped). */
  function render(d) {
    $("active").textContent = "Bitcoin Core";
    $("coreVer").textContent = d.core && d.core.installed ? d.core.version : T("nodesw.not_installed");
    $("running").textContent = d.running ? T("nodesw.yes") : T("nodesw.no");
    renderWalletWarn(d);
    renderPrev("core", d);
    if (window.KnotsBrand) window.KnotsBrand.apply("core");
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
          el.textContent = bn ? T("nodesw.build_rev", { ver: ver, rev: bn }) : ver;
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
          banner(apiErr(d, "nodesw.err.status_failed"), true);
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
          banner(opVerdict(op, r), r.state !== "ok");
          if (done) done(r.state === "ok");
          return;
        }
        if (Date.now() - start > 900000) {
          banner(T("nodesw.op.slow"), true);
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

  $("btnInstall").onclick = function () {
    var impl = $("installImpl").value;
    var fileInput = $("tarball");
    var file = fileInput && fileInput.files && fileInput.files[0];
    var confirmTok = ($("confirmInstall").value || "").trim();
    var sha = ($("sha256").value || "").trim();
    var auth = authPair("authUser", "authPass");
    if (!auth) return;
    if (!file) {
      banner(T("nodesw.install.no_file"), true);
      return;
    }
    if (confirmTok !== "INSTALL") {
      banner(T("nodesw.type_word", { word: "INSTALL" }), true);
      return;
    }
    if (needWalletAck()) {
      banner(T("nodesw.install.wallet_ack"), true);
      return;
    }
    if (!/aarch64/i.test(file.name)) {
      banner(T("nodesw.install.bad_name"), true);
      return;
    }
    if (
      !confirmPopup(T("nodesw.install.confirm_title", { name: implName(impl), file: file.name }), [
        T("nodesw.install.confirm_keep"),
        T("nodesw.confirm.chain"),
        T("nodesw.confirm.restart")
      ])
    ) {
      banner(T("nodesw.install.cancelled"), false);
      return;
    }
    $("btnInstall").disabled = true;
    $("installHint").textContent = T("nodesw.install.uploading", {
      file: file.name,
      mib: Math.round(file.size / 1048576)
    });
    banner(T("nodesw.install.installing", { name: implName(impl) }), false);
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
          banner(apiErr(d, "nodesw.install.failed"), true);
          return;
        }
        $("confirmInstall").value = "";
        $("sha256").value = "";
        $("authPass").value = "";
        if (fileInput) fileInput.value = "";
        if ($("walletAck")) $("walletAck").checked = false;
        banner(T("nodesw.install.accepted"), false);
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
      banner(T("nodesw.type_word", { word: "ROLLBACK" }), true);
      return;
    }
    if (needWalletAck()) {
      banner(T("nodesw.rollback.wallet_ack"), true);
      return;
    }
    if (
      !confirmPopup(T("nodesw.rollback.confirm_title", { name: implName(impl) }), [
        T("nodesw.confirm.chain"),
        T("nodesw.confirm.restart")
      ])
    ) {
      banner(T("nodesw.rollback.cancelled"), false);
      return;
    }
    var btn = $("btnRollback" + (impl === "core" ? "Core" : "Knots"));
    if (btn) btn.disabled = true;
    banner(T("nodesw.rollback.rolling_back", { name: implName(impl) }), false);
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
          banner(apiErr(d, "nodesw.rollback.failed"), true);
          return;
        }
        $("confirmRollback").value = "";
        $("authPass").value = "";
        if ($("walletAck")) $("walletAck").checked = false;
        banner(T("nodesw.rollback.accepted"), false);
        return pollOp("rollback", function () {
          if (btn) btn.disabled = false;
        });
      })
      .catch(function (e) {
        if (btn) btn.disabled = false;
        banner(String(e), true);
      });
  }

  $("btnRollbackCore").onclick = function () {
    doRollback("core");
  };

  /* Language loaded or changed: re-draw the values this script wrote. */
  if (window.KnotsI18n && window.KnotsI18n.onChange) {
    window.KnotsI18n.onChange(function () {
      refresh();
    });
  }

  refresh();
  setInterval(refresh, 20000);
})();
