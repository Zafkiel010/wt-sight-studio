// coi-serviceworker.js — unlock SharedArrayBuffer (ONNX multi-threading) on hosts
// that can't send COOP/COEP headers (e.g. GitHub Pages).
// Page side: registers this same file as a service worker, reloads once so the
// document itself gets the headers. Adapted from gzuidhof/coi-serviceworker (MIT).
(function () {
  var secure = location.protocol === 'https:' ||
    location.hostname === '127.0.0.1' || location.hostname === 'localhost';
  if (typeof window !== 'undefined') {
    // Running as a page script
    if (!window.crossOriginIsolated && secure && 'serviceWorker' in navigator) {
      window.addEventListener('load', function () {
        navigator.serviceWorker.register('coi-serviceworker.js', { scope: './' }).then(function (reg) {
          var tryReload = function () {
            if (!navigator.serviceWorker.controller) window.location.reload();
          };
          if (reg.active) { tryReload(); return; }
          var sw = reg.installing || reg.waiting;
          if (sw) sw.addEventListener('statechange', function () {
            if (sw.state === 'activated') tryReload();
          });
        }).catch(function () { /* SW unavailable — stay single-threaded */ });
      });
    }
  } else if (typeof self !== 'undefined') {
    // Running as the service worker itself
    self.addEventListener('install', function () { self.skipWaiting(); });
    self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });
    self.addEventListener('fetch', function (e) {
      var r = e.request;
      if (r.cache === 'only-if-cached' && r.mode !== 'same-origin') return;
      e.respondWith(fetch(r).then(function (res) {
        if (res.status === 0) return res;
        var h = new Headers(res.headers);
        h.set('Cross-Origin-Embedder-Policy', 'require-corp');
        h.set('Cross-Origin-Opener-Policy', 'same-origin');
        h.set('Cross-Origin-Resource-Policy', 'same-origin');
        return new Response(res.body, { status: res.status, statusText: res.statusText, headers: h });
      }).catch(function () { return Response.error(); }));
    });
  }
})();
