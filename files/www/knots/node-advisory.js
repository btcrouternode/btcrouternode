/* SPDX-License-Identifier: GPL-2.0-only
 * Known security issues in the node software this image ships, shown as a
 * popup whenever someone chooses or runs an affected version: Setup (node
 * step), the Node page (switch), and Node Status (once per visit while it
 * runs). Bitcoin Knots stays on the release that follows the main Bitcoin
 * chain (29.3.knots20260507); no such Knots release has the fix yet, while the
 * shipped Bitcoin Core (29.5) does. Remove an entry when a fixed version ships.
 */
(function () {
  var ADVISORIES = {
    knots: {
      versions: ["v29.3.knots20260507", "29.3.knots20260507"],
      title: "Known security issue in Bitcoin Knots",
      lines: [
        "The Bitcoin Knots version in this firmware (29.3.knots20260507) has a known " +
          "vulnerability, CVE-2026-117349 (rated Medium by Bitcoin Core): a malicious peer " +
          "can make the node use more and more memory until it crashes.",
        "Your coins and the blockchain on the drive are not at risk, but the node can stop " +
          "until it restarts.",
        "Bitcoin Core in this firmware (29.5) has the fix. There is no Knots release with the " +
          "fix that stays on the main Bitcoin chain yet, so we recommend Bitcoin Core."
      ],
      url: "https://bitcoincore.org/en/2026/10/28/disclose-fpausesend-oom/"
    }
  };

  function forImpl(impl, version) {
    var a = ADVISORIES[impl];
    if (!a) return null;
    /* Unknown version (e.g. Setup, before the drive is read): the shipped one. */
    if (version && a.versions.indexOf(String(version).trim()) < 0) return null;
    return a;
  }

  /* Resolves "core" (switch to the fixed Core) or "keep". Plain DOM — every
     page has app.css (.setup-modal, .panel, .btn). */
  function show(a, opts) {
    opts = opts || {};
    return new Promise(function (resolve) {
      var wrap = document.createElement("div");
      wrap.className = "setup-modal";
      wrap.setAttribute("role", "alertdialog");
      wrap.setAttribute("aria-modal", "true");
      wrap.setAttribute("aria-labelledby", "nodeAdvisoryTitle");
      var panel = document.createElement("div");
      panel.className = "panel";
      panel.style.maxWidth = "32rem";
      panel.style.margin = "1rem";
      /* .panel is see-through (--bg-elev); a warning must be readable */
      panel.style.background = "var(--bg)";
      panel.style.maxHeight = "90vh";
      panel.style.overflowY = "auto";
      var h = document.createElement("h3");
      h.id = "nodeAdvisoryTitle";
      h.textContent = a.title;
      panel.appendChild(h);
      a.lines.forEach(function (line) {
        var p = document.createElement("p");
        p.className = "muted";
        p.textContent = line;
        panel.appendChild(p);
      });
      var more = document.createElement("p");
      var link = document.createElement("a");
      link.href = a.url;
      link.target = "_blank";
      link.rel = "noopener";
      link.textContent = "Read the advisory (bitcoincore.org)";
      more.appendChild(link);
      panel.appendChild(more);
      var row = document.createElement("p");
      var useCore = document.createElement("button");
      useCore.type = "button";
      useCore.className = "btn btn-accent";
      useCore.textContent = opts.coreLabel || "Use Bitcoin Core (recommended)";
      var keep = document.createElement("button");
      keep.type = "button";
      keep.className = "btn";
      keep.textContent = opts.keepLabel || "Run Knots anyway";
      row.appendChild(useCore);
      row.appendChild(document.createTextNode(" "));
      row.appendChild(keep);
      panel.appendChild(row);
      wrap.appendChild(panel);
      function done(v) {
        document.removeEventListener("keydown", onKey);
        if (wrap.parentNode) wrap.parentNode.removeChild(wrap);
        resolve(v);
      }
      function onKey(e) {
        /* Escape: the safe answer for a choice (Core); "keep" on Node Status */
        if (e.key === "Escape") done(opts.escape || "core");
      }
      useCore.onclick = function () {
        done("core");
      };
      keep.onclick = function () {
        done("keep");
      };
      document.addEventListener("keydown", onKey);
      document.body.appendChild(wrap);
      useCore.focus();
    });
  }

  /* Choosing impl: resolves true to go ahead with it, false to take Core. */
  function confirmChoice(impl, version) {
    var a = forImpl(impl, version);
    if (!a) return Promise.resolve(true);
    return show(a).then(function (v) {
      return v === "keep";
    });
  }

  window.KnotsNodeAdvisory = {
    forImpl: forImpl,
    show: show,
    confirmChoice: confirmChoice
  };
})();
