/* SPDX-License-Identifier: GPL-2.0-only */
/* Shared OS detection + primary trust CTA for Setup / tls.html (N13 / U17) */
(function (global) {
  function detectOs() {
    var ua = navigator.userAgent || "";
    var plat = navigator.platform || "";
    if (/iPhone|iPad|iPod/.test(ua) || (plat === "MacIntel" && navigator.maxTouchPoints > 1))
      return "ios";
    if (/Android/i.test(ua)) return "android";
    if (/Win/i.test(plat) || /Windows/i.test(ua)) return "windows";
    if (/Mac/i.test(plat) || /Macintosh/i.test(ua)) return "mac";
    if (/Linux/i.test(plat) || /Linux/i.test(ua)) return "linux";
    return "windows";
  }

  /* Phones and tablets (iPadOS reports as a Mac: touch points give it away). */
  function isPhoneOrTablet() {
    var os = detectOs();
    return os === "ios" || os === "android";
  }

  function isUbuntu() {
    return /Ubuntu/i.test(navigator.userAgent || "");
  }

  function isLinuxDesktop() {
    return detectOs() === "linux";
  }

  function lanDropConfirmLines() {
    var os = isUbuntu() ? "Ubuntu" : "Linux";
    return [
      os +
        " will show Ethernet as disconnected when the router restarts. That is " +
        os +
        " NetworkManager, not a failed update.",
      "Leave the cable plugged in.",
      "If " +
        os +
        " turns LAN off, open Settings → Network and click the wired connection back on.",
      "Turn on Connect automatically for that wired connection so it comes back after reboot.",
      "Keep the progress tab open. Do not power-cycle the router."
    ];
  }

  var labels = {
    windows: "Windows",
    mac: "macOS",
    linux: "Linux"
  };

  /* One primary download per OS — scripts fetch the CA themselves where possible */
  function detectBrowser() {
    var ua = navigator.userAgent || "";
    if (/Firefox\//i.test(ua)) return "firefox";
    if (/Edg\//i.test(ua)) return "edge";
    if (/Chrome\//i.test(ua) && !/Edg\//i.test(ua)) return "chrome";
    if (/Safari\//i.test(ua) && !/Chrome\//i.test(ua)) return "safari";
    return "other";
  }

  function updateDownloadTip() {
    var el = document.getElementById("tlsDownloadTip");
    if (!el || el.getAttribute("data-static") === "1") return;
    var br = detectBrowser();
    if (br === "firefox") {
      el.innerHTML =
        "<strong>Firefox download step:</strong> After you tap the orange button, look at the " +
        "<strong>top of the Firefox window</strong> or the <strong>downloads arrow</strong>. " +
        "You must click <strong>Allow</strong> or <strong>Save File</strong> — otherwise the file never downloads. " +
        "Choose <strong>Save File</strong>, not “Open with”.";
    }
  }

  function primaryAction(os) {
    switch (os) {
      case "windows":
        return {
          href: "/tls/install-windows.bat",
          download: "install-bitcoin-node-trust.bat",
          label: "Enable Secure Connection",
          hint: "If the browser asks Allow / Save / Keep (Firefox often does), click that first. Then open the file from Downloads and approve Windows prompts."
        };
      case "mac":
        /* Script Editor link (owner test 2026-10-25: smooth; the .terminal
           file was refused by macOS): Allow → ▶ Run → one password box. */
        return {
          href: macScriptEditorHref(trustHost()),
          download: null,
          label: "Enable Secure Connection",
          hint: "Click Allow, then the ▶ Run button in Script Editor, then type your Mac password."
        };
      case "linux":
        /* Ubuntu / Debian / Mint package: App Center → Install → password
           (owner, 2026-10-25). Other Linux: the Terminal command fallback. */
        return {
          href: "/tls/rnode-secure-connection.deb",
          download: "rnode-secure-connection.deb",
          label: "Enable Secure Connection",
          hint: "Open the downloaded file — App Center opens: Install, then your password. The secure page reopens by itself."
        };
      default:
        return primaryAction("windows");
    }
  }

  function routerHttpBase() {
    /* Host per D2 (shell.js KnotsIue.host). */
    if (location.protocol === "https:") return "https://" + (window.KnotsIue ? window.KnotsIue.host() : "rnode.local");
    return "http://" + (window.KnotsIue ? window.KnotsIue.host() : "rnode.local");
  }

  function trustHost() {
    return window.KnotsIue ? window.KnotsIue.host() : location.hostname || "rnode.local";
  }

  /* Mac: one command (P4: private temp file, then run it; curl does not
     quarantine). install-macos.command trusts the CA in the user's keychain
     — macOS asks for the password once — and reopens Setup over HTTPS. */
  function macTrustCommand(host) {
    return "f=$(mktemp) && curl -fsSL http://" + host + "/tls/install-macos.command -o $f && bash $f http://" + host;
  }

  /* Apple's Script Editor URL protocol: opens a new script with the command;
     the person clicks Run. No download, no profile, no developer signing. */
  function macScriptEditorHref(host) {
    return "applescript://com.apple.scripteditor?action=new&script=" +
      encodeURIComponent('do shell script "' + macTrustCommand(host) + '"');
  }

  function absoluteTrustHref(path) {
    if (!path) return path;
    if (/^[a-z][a-z0-9+.-]*:/i.test(path)) return path;   /* http(s):, applescript: … */
    return routerHttpBase() + path;
  }

  function rewritePanelLinks(root) {
    if (!root) return;
    var links = root.querySelectorAll("a[href^='/']");
    for (var i = 0; i < links.length; i++) {
      var href = links[i].getAttribute("href");
      if (href && (href.indexOf("/tls") === 0 || href === "/knots-ca.crt")) {
        links[i].href = absoluteTrustHref(href);
      }
    }
  }

  function applyCtaAttrs(a, act) {
    if (!a || !act) return;
    a.href = absoluteTrustHref(act.href);
    if (!a.getAttribute("data-i18n")) a.textContent = act.label;
    if (act.download) a.setAttribute("download", act.download);
    else a.removeAttribute("download");
  }

  function updatePrimaryCta(os) {
    var act = primaryAction(os);
    applyCtaAttrs(document.getElementById("tlsPrimaryCta"), act);
    if (os === "linux") applyCtaAttrs(document.getElementById("tlsLinuxCta"), act);
    var hint = document.getElementById("tlsPrimaryHint");
    if (hint) hint.textContent = act.hint || "";
  }

  function copyText(text) {
    if (!text) return Promise.reject(new Error("empty"));
    text = String(text);

    function legacyCopy() {
      return new Promise(function (resolve, reject) {
        var ta = document.createElement("textarea");
        ta.value = text;
        ta.setAttribute("readonly", "");
        /* iOS / some WebKit builds ignore off-screen + readonly selects */
        ta.style.cssText =
          "position:fixed;top:0;left:0;width:2em;height:2em;padding:0;" +
          "border:none;outline:none;box-shadow:none;background:transparent;opacity:0;";
        document.body.appendChild(ta);
        ta.focus();
        ta.select();
        try {
          ta.setSelectionRange(0, text.length);
        } catch (e0) {}
        var ok = false;
        try {
          ok = document.execCommand("copy");
        } catch (e1) {
          ok = false;
        }
        document.body.removeChild(ta);
        if (ok) resolve();
        else reject(new Error("copy failed"));
      });
    }

    /* Clipboard API is often present but rejects on LAN HTTPS / strict
       permission policies — always fall back to execCommand. */
    if (
      window.isSecureContext &&
      navigator.clipboard &&
      typeof navigator.clipboard.writeText === "function"
    ) {
      return navigator.clipboard.writeText(text).catch(function () {
        return legacyCopy();
      });
    }
    return legacyCopy();
  }

  function selectCopyableText(row) {
    var mono = row && row.querySelector(".mono, code");
    if (!mono || !window.getSelection) return false;
    try {
      var range = document.createRange();
      range.selectNodeContents(mono);
      var sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      return true;
    } catch (e) {
      return false;
    }
  }

  function bindCopyButtons(root) {
    var scope = root || document;
    var rows = scope.querySelectorAll(".copyable, [data-copy]");
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      if (!row.querySelector(".btn-copy")) {
        var btn = document.createElement("button");
        btn.type = "button";
        btn.className = "btn btn-copy";
        btn.textContent = "Copy";
        row.appendChild(btn);
      }
    }
  }

  /* Capture-phase delegation — works even if bindOsTabs ran late / again */
  function installCopyDelegation() {
    if (typeof document === "undefined") return;
    if (document.documentElement.getAttribute("data-knots-copy-delegated") === "1")
      return;
    document.documentElement.setAttribute("data-knots-copy-delegated", "1");

    document.addEventListener(
      "click",
      function (e) {
        var t = e.target;
        if (!t || !t.closest) return;
        var btn = t.closest(".btn-copy");
        if (!btn) return;
        /* One-liner wrap uses data-copy (and copyable). Match either so Copy
           cannot silently no-op when class is missing (U17 Linux wget). */
        var row = btn.closest(".copyable, [data-copy]");
        if (!row) return;
        e.preventDefault();
        e.stopPropagation();

        var text = (row.getAttribute("data-copy") || "").replace(/^\s+|\s+$/g, "");
        if (!text) {
          var mono = row.querySelector(".mono, code");
          text = mono ? String(mono.textContent || "").replace(/^\s+|\s+$/g, "") : "";
        }
        if (!text) return;

        var label = btn.getAttribute("data-copy-label") || "Copy";
        if (label === "Copied" || /Ctrl\+C|Select/i.test(label)) label = "Copy";
        btn.setAttribute("data-copy-label", "Copy");

        copyText(text).then(
          function () {
            btn.textContent = "Copied";
            btn.classList.add("copied");
            setTimeout(function () {
              btn.textContent = "Copy";
              btn.classList.remove("copied");
            }, 1600);
          },
          function () {
            selectCopyableText(row);
            btn.textContent = "Selected — Ctrl+C / ⌘C";
            setTimeout(function () {
              btn.textContent = "Copy";
            }, 2800);
          }
        );
      },
      true
    );
  }

  installCopyDelegation();

  function bindOsTabs(opts) {
    opts = opts || {};
    var tabRoot = document.getElementById(opts.tabsId || "tlsOsTabs");
    var labelEl = document.getElementById(opts.labelId || "tlsOsLabel");
    var panelSel = opts.panelSelector || ".tls-panel";
    var otherBtn = document.getElementById(opts.otherId || "tlsOsOtherBtn");
    var otherWrap = document.getElementById(opts.otherWrapId || "tlsOsOtherWrap");
    var detectedOnly = !!opts.detectedOnly;

    function show(os) {
      var tabs = tabRoot ? tabRoot.querySelectorAll("button[data-os]") : [];
      var panels = document.querySelectorAll(panelSel);
      for (var i = 0; i < tabs.length; i++) {
        var on = tabs[i].getAttribute("data-os") === os;
        tabs[i].classList.toggle("active", on);
        tabs[i].setAttribute("aria-selected", on ? "true" : "false");
      }
      for (var j = 0; j < panels.length; j++) {
        var match = panels[j].getAttribute("data-os") === os;
        panels[j].hidden = !match;
        if (match) {
          rewritePanelLinks(panels[j]);
          bindCopyButtons(panels[j]);
        }
      }
      if (labelEl) labelEl.textContent = labels[os] || os;
      updatePrimaryCta(os);
      if (typeof opts.onShow === "function") opts.onShow(os);
    }

    installCopyDelegation();
    var os = detectOs();
    show(os);
    updateDownloadTip();
    bindCopyButtons(document);

    if (detectedOnly) {
      if (tabRoot) tabRoot.hidden = true;
      if (otherWrap) otherWrap.hidden = false;
      if (otherBtn && !otherBtn.getAttribute("data-bound")) {
        otherBtn.setAttribute("data-bound", "1");
        otherBtn.addEventListener("click", function () {
          if (tabRoot) tabRoot.hidden = false;
          if (otherWrap) otherWrap.hidden = true;
        });
      }
    } else {
      if (tabRoot) tabRoot.hidden = false;
      if (otherWrap) otherWrap.hidden = true;
    }

    if (tabRoot && !tabRoot.getAttribute("data-bound")) {
      tabRoot.setAttribute("data-bound", "1");
      tabRoot.addEventListener("click", function (e) {
        var btn = e.target.closest("button[data-os]");
        if (!btn) return;
        show(btn.getAttribute("data-os"));
      });
    }
    return os;
  }

  /* D2: static help text names rnode.local; show the host this browser
     actually uses (LAN IP on clients without mDNS) in links, copy buttons
     and the monospace examples. */
  function localizeHost(rootEl) {
    var h = global.KnotsIue && global.KnotsIue.host ? global.KnotsIue.host() : "rnode.local";
    if (h === "rnode.local" || !rootEl || !rootEl.querySelectorAll) return;
    var swap = function (v) {
      return String(v).replace(/rnode\.local/g, h);
    };
    var els = rootEl.querySelectorAll("a[href*='rnode.local'], [data-copy*='rnode.local'], .mono");
    for (var i = 0; i < els.length; i++) {
      var el = els[i];
      if (el.getAttribute("href")) el.setAttribute("href", swap(el.getAttribute("href")));
      if (el.getAttribute("data-copy")) el.setAttribute("data-copy", swap(el.getAttribute("data-copy")));
      if (el.classList && el.classList.contains("mono") && el.children.length === 0) {
        el.textContent = swap(el.textContent);
      }
    }
  }
  if (typeof document !== "undefined") {
    var runLocalize = function () {
      localizeHost(document);
    };
    if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", runLocalize);
    else runLocalize();
  }

  global.KnotsTlsOs = {
    detectOs: detectOs,
    isPhoneOrTablet: isPhoneOrTablet,
    macTrustCommand: macTrustCommand,
    macScriptEditorHref: macScriptEditorHref,
    isUbuntu: isUbuntu,
    isLinuxDesktop: isLinuxDesktop,
    lanDropConfirmLines: lanDropConfirmLines,
    detectBrowser: detectBrowser,
    labels: labels,
    primaryAction: primaryAction,
    routerHttpBase: routerHttpBase,
    absoluteTrustHref: absoluteTrustHref,
    bindOsTabs: bindOsTabs,
    updatePrimaryCta: updatePrimaryCta,
    updateDownloadTip: updateDownloadTip,
    bindCopyButtons: bindCopyButtons,
    copyText: copyText,
    localizeHost: localizeHost
  };
})(window);
