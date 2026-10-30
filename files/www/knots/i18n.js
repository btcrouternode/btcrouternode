/* SPDX-License-Identifier: GPL-2.0-only */
/* Knots UI i18n — U19. Loads /i18n/<lang>.json; missing keys fall back to English. */
(function (global) {
  var dict = {};
  var en = {};
  var lang = "en";

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
    var nodes = root.querySelectorAll("[data-i18n]");
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var key = el.getAttribute("data-i18n");
      if (!key) continue;
      /* No string in this language or English: keep the page's own text
         (and its markup) instead of showing the key. */
      if (dict[key] == null && en[key] == null) continue;
      var attr = el.getAttribute("data-i18n-attr");
      var val = t(key);
      if (attr) el.setAttribute(attr, val);
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
    if (!en || !Object.keys(en).length) {
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
    apply: apply,
    loadLang: loadLang,
    detectInitial: detectInitial,
    getLang: function () {
      return lang;
    },
    setStoredLang: setStoredLang
  };
})(window);
