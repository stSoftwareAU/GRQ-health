// GRQ Health Dashboard Service Worker
// Version: 1.0.41

const CACHE_NAME = 'grq-health-v1.0.41';
const STATIC_CACHE_NAME = 'grq-health-static-v1.0.41';

// Files to cache for offline functionality
const STATIC_FILES = [
  './',
  './index.html',
  './styles.css',
  './dashboard.js?v=1.0.41',
  './medical-check.png',
  './unhealthy.png',
  './manifest.json',
  './browserconfig.xml',
  // Bootstrap CSS and JS from CDN
  'https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css',
  'https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js',
  'https://cdn.jsdelivr.net/npm/bootstrap-icons@1.10.5/font/bootstrap-icons.css'
];

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
          
          // For data requests (index.json), add cache indicator header
          if (url.pathname.endsWith('index.json')) {
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
            if (url.pathname.endsWith('index.json')) {
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
      // Try to fetch fresh health data
      fetch('./index.json')
        .then((response) => {
          if (response.ok) {
            return response.json();
          }
          throw new Error('Failed to fetch health data');
        })
        .then((data) => {
          // Cache the fresh data
          return caches.open(CACHE_NAME)
            .then((cache) => {
              return cache.put('./index.json', new Response(JSON.stringify(data)));
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
