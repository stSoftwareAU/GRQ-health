// GRQ Health Dashboard Service Worker
// Version: 1.1.31

// Issue #213: the health data loader is shared with the dashboard so the
// service worker syncs the same per-host documents the page reads. Versioned
// like every other asset, so an updated worker cannot execute a stale loader.
importScripts('./host-status.js?v=1.1.31');

const CACHE_NAME = 'grq-health-v1.1.31';
const STATIC_CACHE_NAME = 'grq-health-static-v1.1.31';

// Files to cache for offline functionality
const STATIC_FILES = [
  './',
  './index.html',
  './styles.css',
  './theme.css?v=1.1.19',
  './theme.js?v=1.1.19',
  './host-status.js?v=1.1.31',
  './dashboard.js?v=1.1.31',
  './medical-check.png',
  './unhealthy.png',
  './manifest.json',
  './browserconfig.xml',
  // Bootstrap CSS and JS from CDN
  'https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css',
  'https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js',
  'https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.5/font/bootstrap-icons.css'
];

// Issue #213: where the background sync parks the merged fleet snapshot.
const OFFLINE_SNAPSHOT_URL = './host-status/offline-snapshot.json';

// Issue #213: health data is the fleet-wide index.json plus the per-host
// documents under host-status/. Both are treated as data, not static assets.
function isHealthDataPath(pathname) {
  return pathname.endsWith('index.json') || pathname.includes('/host-status/');
}

// Install event - cache static files
self.addEventListener('install', (event) => {
  console.log('Service Worker: Installing...');
  
  event.waitUntil(
    caches.open(STATIC_CACHE_NAME)
      .then((cache) => {
        console.log('Service Worker: Caching static files');
        return cache.addAll(STATIC_FILES);
      })
      .then(() => {
        console.log('Service Worker: Static files cached successfully');
        return self.skipWaiting();
      })
      .catch((error) => {
        console.error('Service Worker: Failed to cache static files', error);
      })
  );
});

// Activate event - clean up old caches
self.addEventListener('activate', (event) => {
  console.log('Service Worker: Activating...');
  
  event.waitUntil(
    caches.keys()
      .then((cacheNames) => {
        return Promise.all(
          cacheNames.map((cacheName) => {
            // Delete old caches that don't match current version
            if (cacheName !== CACHE_NAME && cacheName !== STATIC_CACHE_NAME) {
              console.log('Service Worker: Deleting old cache', cacheName);
              return caches.delete(cacheName);
            }
          })
        );
      })
      .then(() => {
        console.log('Service Worker: Activated successfully');
        return self.clients.claim();
      })
  );
});

// Fetch event - serve from cache when offline
self.addEventListener('fetch', (event) => {
  const request = event.request;
  const url = new URL(request.url);
  
  // Skip non-GET requests
  if (request.method !== 'GET') {
    return;
  }
  
  // Skip chrome-extension and other non-http requests
  if (!request.url.startsWith('http')) {
    return;
  }
  
  event.respondWith(
    caches.match(request)
      .then((cachedResponse) => {
        // If we have a cached version, return it
        if (cachedResponse) {
          console.log('Service Worker: Serving from cache', request.url);
          
          // For data requests, add cache indicator header
          if (isHealthDataPath(url.pathname)) {
            const response = cachedResponse.clone();
            response.headers.set('X-Served-From-Cache', 'true');
            response.headers.set('X-Validation-Warning', 'CACHED-DATA');
            return response;
          }
          
          return cachedResponse;
        }
        
        // If not in cache, try to fetch from network
        return fetch(request)
          .then((response) => {
            // Don't cache non-successful responses
            if (!response || response.status !== 200 || response.type !== 'basic') {
              return response;
            }

            // Issue #213: health data is requested with a unique ?t= cache
            // buster, so a cached copy can never be matched again. Caching it
            // would grow the cache without bound — one dead entry per host per
            // refresh. The background sync keeps the offline snapshot instead.
            if (isHealthDataPath(url.pathname)) {
              return response;
            }
            
            // Clone the response for caching
            const responseToCache = response.clone();
            
            // Cache the response for future use
            caches.open(CACHE_NAME)
              .then((cache) => {
                cache.put(request, responseToCache);
              });
            
            return response;
          })
          .catch((error) => {
            console.log('Service Worker: Network request failed', request.url, error);
            
            // For navigation requests, return the cached index.html
            if (request.mode === 'navigate') {
              return caches.match('./index.html');
            }
            
            // For other requests, return a basic offline response
            if (isHealthDataPath(url.pathname)) {
              return new Response(
                JSON.stringify({
                  error: 'Offline',
                  message: 'No network connection available. Health data cannot be loaded.',
                  timestamp: new Date().toISOString()
                }),
                {
                  status: 503,
                  statusText: 'Service Unavailable',
                  headers: {
                    'Content-Type': 'application/json',
                    'X-Served-From-Cache': 'true',
                    'X-Validation-Warning': 'CACHED-DATA'
                  }
                }
              );
            }
            
            throw error;
          });
      })
  );
});

// Handle background sync for health data updates
self.addEventListener('sync', (event) => {
  if (event.tag === 'health-data-sync') {
    console.log('Service Worker: Background sync triggered');
    event.waitUntil(
      // Try to fetch fresh health data (per-host documents merged with the
      // legacy fleet-wide index.json, exactly as the dashboard reads it).
      self.GRQHostStatus.loadHostStatus(fetch, Date.now())
        .then((health) => {
          health.errors.forEach((message) => console.warn('Service Worker: health data:', message));
          // Cache the merged snapshot for offline use, under its own key —
          // it is a merge of every source, not a copy of the legacy file.
          return caches.open(CACHE_NAME)
            .then((cache) => {
              return cache.put(OFFLINE_SNAPSHOT_URL, new Response(JSON.stringify(health.data)));
            });
        })
        .then(() => {
          console.log('Service Worker: Health data synced successfully');
          // Notify clients that new data is available
          return self.clients.matchAll()
            .then((clients) => {
              clients.forEach((client) => {
                client.postMessage({
                  type: 'HEALTH_DATA_UPDATED',
                  timestamp: new Date().toISOString()
                });
              });
            });
        })
        .catch((error) => {
          console.error('Service Worker: Background sync failed', error);
        })
    );
  }
});

// Handle push notifications (for future use)
self.addEventListener('push', (event) => {
  console.log('Service Worker: Push notification received');
  
  const options = {
    body: event.data ? event.data.text() : 'Health status update available',
    icon: './icons/icon-192x192.png',
    badge: './icons/icon-72x72.png',
    vibrate: [100, 50, 100],
    data: {
      dateOfArrival: Date.now(),
      primaryKey: 1
    },
    actions: [
      {
        action: 'explore',
        title: 'View Dashboard',
        icon: './icons/icon-192x192.png'
      },
      {
        action: 'close',
        title: 'Close',
        icon: './icons/icon-192x192.png'
      }
    ]
  };
  
  event.waitUntil(
    self.registration.showNotification('GRQ Health Dashboard', options)
  );
});

// Handle notification clicks
self.addEventListener('notificationclick', (event) => {
  console.log('Service Worker: Notification clicked');
  
  event.notification.close();
  
  if (event.action === 'explore') {
    event.waitUntil(
      clients.openWindow('./')
    );
  }
});

// Message handling for communication with main thread
self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  
  if (event.data && event.data.type === 'GET_VERSION') {
    event.ports[0].postMessage({
      version: CACHE_NAME
    });
  }
});
