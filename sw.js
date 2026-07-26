/* =====================================================================
   Service Worker — دليل الهاتف PWA
   الاستراتيجية: Cache First للملفات الثابتة، Network First للخارجية
   ===================================================================== */

const CACHE_NAME = 'phone-directory-v1';
const OFFLINE_PAGE = './index.html';

/* الملفات اللي بتتحمل في أول تثبيت */
const PRECACHE_ASSETS = [
  './index.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png'
];

/* الـ CDN اللي بنحاول نستحملهم، ولو مش موجود أوفلاين نكمل بدونهم */
const CDN_URLS = [
  'https://cdnjs.cloudflare.com/ajax/libs/xlsx/0.18.5/xlsx.full.min.js',
  'https://cdnjs.cloudflare.com/ajax/libs/mammoth/1.6.0/mammoth.browser.min.js',
  'https://fonts.googleapis.com/css2?family=Almarai:wght@400;700;800&family=Cairo:wght@400;500;600;700&family=Lalezar&display=swap'
];

/* ===== Install: كاش الملفات الأساسية ===== */
self.addEventListener('install', function (event) {
  event.waitUntil(
    caches.open(CACHE_NAME).then(function (cache) {
      console.log('[SW] Pre-caching app shell...');
      /* نكاش الأساسيات، وبعدين نحاول الـ CDN بشكل منفصل */
      return cache.addAll(PRECACHE_ASSETS).then(function () {
        /* نحاول نكاش الـ CDN بشكل غير blocking */
        return Promise.allSettled(
          CDN_URLS.map(function (url) {
            return fetch(url, { mode: 'cors' })
              .then(function (response) {
                if (response.ok) {
                  return cache.put(url, response);
                }
              })
              .catch(function () {
                console.log('[SW] CDN not reachable (will retry online):', url);
              });
          })
        );
      });
    }).then(function () {
      console.log('[SW] Install complete — taking control immediately');
      return self.skipWaiting();
    })
  );
});

/* ===== Activate: امسح الكاش القديم ===== */
self.addEventListener('activate', function (event) {
  event.waitUntil(
    caches.keys().then(function (cacheNames) {
      return Promise.all(
        cacheNames
          .filter(function (name) { return name !== CACHE_NAME; })
          .map(function (name) {
            console.log('[SW] Deleting old cache:', name);
            return caches.delete(name);
          })
      );
    }).then(function () {
      console.log('[SW] Activated — claiming all clients');
      return self.clients.claim();
    })
  );
});

/* ===== Fetch: الاستراتيجية الرئيسية ===== */
self.addEventListener('fetch', function (event) {
  const url = new URL(event.request.url);

  /* تجاهل الـ chrome-extension وغيرها */
  if (!event.request.url.startsWith('http')) return;

  /* تجاهل POST requests (ملفات الاستيراد) */
  if (event.request.method !== 'GET') return;

  /* ملفات الـ fonts من Google: Stale-While-Revalidate */
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
    event.respondWith(staleWhileRevalidate(event.request));
    return;
  }

  /* ملفات CDN (xlsx, mammoth): Cache First */
  if (url.hostname === 'cdnjs.cloudflare.com') {
    event.respondWith(cacheFirst(event.request));
    return;
  }

  /* ملفات التطبيق نفسه (index.html, manifest, icons): Cache First مع Offline Fallback */
  if (url.origin === self.location.origin) {
    event.respondWith(cacheFirstWithOfflineFallback(event.request));
    return;
  }

  /* أي طلب تاني: Network First */
  event.respondWith(networkFirst(event.request));
});

/* ===== استراتيجيات الـ Fetch ===== */

/* Cache First: رجّع من الكاش، ولو مش موجود اجلب من النت وكاشه */
function cacheFirst(request) {
  return caches.match(request).then(function (cached) {
    if (cached) return cached;
    return fetch(request).then(function (response) {
      if (response && response.ok) {
        var clone = response.clone();
        caches.open(CACHE_NAME).then(function (cache) {
          cache.put(request, clone);
        });
      }
      return response;
    }).catch(function () {
      return new Response('', { status: 503, statusText: 'Offline' });
    });
  });
}

/* Cache First مع Fallback لـ index.html لو الملف مش موجود */
function cacheFirstWithOfflineFallback(request) {
  return caches.match(request).then(function (cached) {
    if (cached) return cached;
    return fetch(request).then(function (response) {
      if (response && response.ok) {
        var clone = response.clone();
        caches.open(CACHE_NAME).then(function (cache) {
          cache.put(request, clone);
        });
      }
      return response;
    }).catch(function () {
      /* ارجع index.html كـ fallback */
      return caches.match(OFFLINE_PAGE);
    });
  });
}

/* Network First: اجلب من النت، ولو فشل رجّع من الكاش */
function networkFirst(request) {
  return fetch(request).then(function (response) {
    if (response && response.ok) {
      var clone = response.clone();
      caches.open(CACHE_NAME).then(function (cache) {
        cache.put(request, clone);
      });
    }
    return response;
  }).catch(function () {
    return caches.match(request).then(function (cached) {
      return cached || new Response('', { status: 503, statusText: 'Offline' });
    });
  });
}

/* Stale While Revalidate: رجّع الكاش فوراً وحدّثه في الخلفية */
function staleWhileRevalidate(request) {
  var fetchPromise = fetch(request).then(function (response) {
    if (response && response.ok) {
      var clone = response.clone();
      caches.open(CACHE_NAME).then(function (cache) {
        cache.put(request, clone);
      });
    }
    return response;
  });
  return caches.match(request).then(function (cached) {
    return cached || fetchPromise;
  });
}
