/* SPDX-License-Identifier: GPL-2.0-only */
/* RNode UI i18n. English is bundled with the page (/i18n/en.js, generated from
   en.json by build/gen-i18n-en.py) so a string is never shown as its key — not
   even on the update / reset pages while the router reboots. Other languages
   load from /i18n/<lang>.json; missing keys fall back to English. */
(function (global) {
  var en = global.KNOTS_I18N_EN || {};
  var dict = en;
  var lang = "en";
  var listeners = [];

  function getStoredLang() {
    try {
      var ls = localStorage.getItem("knots-ui-lang");
      if (ls) return ls;
    } catch (e) {}
    return null;
  }

  function setStoredLang(code) {
    try {
      localStorage.setItem("knots-ui-lang", code);
    } catch (e) {}
  }

  function fetchText(url) {
    return fetch(url, { cache: "no-store" }).then(function (r) {
      if (!r.ok) throw new Error("http " + r.status);
      return r.text();
    });
  }

  function fetchJson(url) {
    return fetch(url, { cache: "no-store" }).then(function (r) {
      if (!r.ok) throw new Error("http " + r.status);
      return r.json();
    });
  }

  function t(key, vars) {
    var s = dict[key];
    if (s == null || s === "") s = en[key];
    if (s == null) s = key;
    if (vars) {
      Object.keys(vars).forEach(function (k) {
        s = String(s).split("{" + k + "}").join(String(vars[k]));
      });
    }
    return s;
  }

  function apply(root) {
    root = root || document;
    var nodes = root.querySelectorAll("[data-i18n], [data-i18n-html]");
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var html = el.hasAttribute("data-i18n-html");
      var key = el.getAttribute(html ? "data-i18n-html" : "data-i18n");
      if (!key) continue;
      /* No string in this language or English: keep the page's own text
         (and its markup) instead of showing the key. */
      if (dict[key] == null && en[key] == null) continue;
      var attr = el.getAttribute("data-i18n-attr");
      var val = t(key);
      if (attr) el.setAttribute(attr, val);
      /* data-i18n-html: our own catalogue strings with simple markup
         (<b>, <code>, <a>) — never data from the router or the user. */
      else if (html) el.innerHTML = val;
      else el.textContent = val;
    }
    if (document.documentElement) {
      document.documentElement.lang = lang.indexOf("zh") === 0 ? "zh-CN" : lang;
    }
  }

  function loadLang(code) {
    code = code || "en";
    lang = code;
    setStoredLang(code);
    var chain = Promise.resolve();
    if (!en || !Object.keys(en).length) {   /* page without en.js */
      chain = fetchJson("/i18n/en.json").then(function (d) {
        en = d || {};
      });
    }
    return chain
      .then(function () {
        if (code === "en") {
          dict = en;
          return;
        }
        return fetchJson("/i18n/" + code + ".json")
          .then(function (d) {
            dict = d || {};
          })
          .catch(function () {
            dict = {};
          });
      })
      .then(function () {
        apply(document);
        for (var i = 0; i < listeners.length; i++) {
          try { listeners[i](lang); } catch (e) {}
        }
        return lang;
      });
  }

  function detectInitial() {
    return fetchText("/ui-lang")
      .then(function (t) {
        return (t || "").replace(/\s+/g, "") || null;
      })
      .catch(function () {
        return getStoredLang();
      })
      .then(function (code) {
        return loadLang(code || "en");
      });
  }

  global.KnotsI18n = {
    t: t,
    /* run fn after every language load (re-draw JS-made text) */
    onChange: function (fn) {
      listeners.push(fn);
    },
    apply: apply,
    loadLang: loadLang,
    detectInitial: detectInitial,
    getLang: function () {
      return lang;
    },
    setStoredLang: setStoredLang
  };
})(window);
