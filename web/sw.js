const CACHE_NAME = 'jev-v2';
const urlsToCache = [
    '/',
    '/index.html',
    '/app.js',
    '/styles.css',
    '/manifest.webmanifest',
];

// Install event - cache static assets
self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(CACHE_NAME)
            .then((cache) => {
                // Try to cache, but don't fail if some files aren't available yet
                return Promise.all(
                    urlsToCache.map(url => {
                        return cache.add(url).catch(err => {
                            console.warn(`Failed to cache ${url}:`, err);
                        });
                    })
                );
            })
    );
    self.skipWaiting();
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then((cacheNames) => {
            return Promise.all(
                cacheNames.map((cacheName) => {
                    if (cacheName !== CACHE_NAME) {
                        return caches.delete(cacheName);
                    }
                })
            );
        })
    );
    self.clients.claim();
});

// Fetch.
//
// The shell is fetched network-first. Cache-first with a fixed cache name meant
// a rebuilt app.js could never reach an installed PWA — not even through a hard
// refresh — so fixes shipped to a phone that kept running the old code. The
// cache is now only a fallback for being offline.
//
// API responses are never cached: they carry approvals, screenshots and
// authenticated state, and a stale one is worse than an error.
self.addEventListener('fetch', (event) => {
    const { request } = event;
    const url = new URL(request.url);

    if (url.origin !== self.location.origin) return;
    if (request.method !== 'GET') return;
    if (url.pathname.startsWith('/api/') || url.pathname === '/ws') return;

    event.respondWith(
        fetch(request)
            .then((response) => {
                if (response && response.status === 200 && response.type === 'basic') {
                    const copy = response.clone();
                    caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
                }
                return response;
            })
            .catch(() => caches.match(request).then(cached => cached || new Response(
                'Offline — cannot reach your Mac.',
                { status: 503, statusText: 'Service Unavailable' }
            )))
    );
});

// Push event - receive push notifications from server
self.addEventListener('push', (event) => {
    let notificationData = {
        title: 'Jev Notification',
        body: 'New approval pending',
        icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192"><rect fill="%23000" width="192" height="192"/><text x="50%" y="50%" font-size="120" font-weight="bold" fill="%23fff" text-anchor="middle" dominant-baseline="central">J</text></svg>',
        badge: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 96 96"><rect fill="%23000" width="96" height="96"/><text x="50%" y="50%" font-size="60" font-weight="bold" fill="%23fff" text-anchor="middle" dominant-baseline="central">!</text></svg>',
        tag: 'jev-approval',
        requireInteraction: true,
        data: {
            approvalId: null,
        },
        actions: [
            {
                action: 'open',
                title: 'View',
                icon: 'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><path d="M19 13h-6v6h-2v-6H5v-2h6V5h2v6h6v2z"/></svg>',
            },
            {
                action: 'close',
                title: 'Dismiss',
            },
        ],
    };

    // Try to parse push event data
    if (event.data) {
        try {
            const data = event.data.json();
            notificationData = {
                ...notificationData,
                title: data.title || notificationData.title,
                body: data.body || notificationData.body,
                data: {
                    ...notificationData.data,
                    ...data,
                },
            };
        } catch (e) {
            // If JSON parsing fails, use the text as body
            notificationData.body = event.data.text();
        }
    }

    event.waitUntil(
        self.registration.showNotification(notificationData.title, notificationData)
    );
});

// Notification click event
self.addEventListener('notificationclick', (event) => {
    const { action, notification } = event;
    const data = notification.data || {};
    notification.close();

    if (action === 'close') return;

    // The Mac sends an absolute URL on its own origin. Comparing client.url to
    // '/' never matched, so an already-open app was ignored and a second window
    // opened every time.
    const target = data.url || self.location.origin + '/';
    const targetOrigin = new URL(target, self.location.origin).origin;

    event.waitUntil(
        clients.matchAll({ type: 'window', includeUncontrolled: true }).then((windows) => {
            for (const client of windows) {
                if (new URL(client.url).origin === targetOrigin && 'focus' in client) {
                    client.postMessage({ type: 'approval-notification', url: target });
                    return client.focus();
                }
            }
            return clients.openWindow ? clients.openWindow(target) : undefined;
        })
    );
});

// Notification close event
self.addEventListener('notificationclose', (event) => {
    console.log('Notification closed:', event.notification.tag);
});

// Message event - handle messages from app
self.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'SKIP_WAITING') {
        self.skipWaiting();
    }
});
