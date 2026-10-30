/* SPDX-License-Identifier: GPL-2.0-only */
/* Retired (review D4, 2026-10-10). This used to cache the Firmware Update /
   Factory Reset wait pages (F150), but those pages are plain HTTP by design
   and browsers never run service workers there; on HTTPS its scope "/" also
   served stale Node/Settings pages. Kept as a kill switch: a browser that
   still has the old worker fetches this on its next update check, which
   deletes the knots-wait caches and unregisters the worker. shell.js also
   unregisters it on every page load. Safe to delete after a few releases. */
self.addEventListener("install", function () {
  self.skipWaiting();
});

self.addEventListener("activate", function (event) {
  event.waitUntil(
    caches
      .keys()
      .then(function (keys) {
        return Promise.all(
          keys
            .filter(function (k) {
              return k.indexOf("knots-wait") === 0;
            })
            .map(function (k) {
              return caches.delete(k);
            })
        );
      })
      .then(function () {
        return self.registration.unregister();
      })
  );
});
