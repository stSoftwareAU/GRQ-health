# GRQ Health Dashboard - PWA Setup Guide

This guide explains how the GRQ Health Dashboard has been configured as a Progressive Web App (PWA).

## PWA Features Implemented

### 1. Web App Manifest (`manifest.json`)
- **App Name**: GRQ Health Dashboard
- **Short Name**: GRQ Health
- **Theme Color**: #28a745 (Bootstrap success green)
- **Background Color**: #28a745
- **Display Mode**: standalone (full-screen app experience)
- **Orientation**: portrait-primary (optimized for mobile)
- **Icons**: Multiple sizes (72x72 to 512x512) for different devices

### 2. Service Worker (`sw.js`)
- **Caching Strategy**: Cache-first for static assets, network-first for data
- **Offline Support**: Limited offline functionality with cached health data
- **Background Sync**: Attempts to sync health data when connection is restored
- **Push Notifications**: Framework ready for future health alerts

### 3. Icons and Branding
- **Base Icon**: `medical-check.png` (existing health check icon)
- **Generated Icons**: All required PWA icon sizes created from base icon
- **Windows Tiles**: `browserconfig.xml` for Windows Start Menu integration

### 4. Offline Functionality
- **Limited Offline Support**: Health monitoring requires network connectivity
- **Cached Data Warning**: Clear indicators when using cached data
- **Offline Color Scheme**: Brown theme to indicate offline mode
- **Error Handling**: Graceful degradation when network is unavailable

## Installation Instructions

### Desktop (Chrome/Edge)
1. Open the GRQ Health Dashboard in Chrome or Edge
2. Look for the install icon in the address bar (⊕ or install icon)
3. Click "Install" when prompted
4. The app will be added to your desktop and app list

### Mobile (iOS Safari)
1. Open the GRQ Health Dashboard in Safari
2. Tap the Share button (square with arrow)
3. Scroll down and tap "Add to Home Screen"
4. Customize the name if desired and tap "Add"

### Mobile (Android Chrome)
1. Open the GRQ Health Dashboard in Chrome
2. Tap the menu (three dots) in the browser
3. Tap "Add to Home screen" or "Install app"
4. Confirm the installation

## Offline Behavior

### What Works Offline
- ✅ App shell (HTML, CSS, JavaScript)
- ✅ Cached health data (if previously loaded)
- ✅ Basic navigation and UI

### What Requires Network
- ❌ Fresh health data updates
- ❌ Real-time monitoring
- ❌ New host discovery

### Offline Indicators
- **Brown Color Scheme**: Indicates offline mode
- **Warning Banner**: Shows when using cached data
- **Error Messages**: Clear communication about connectivity issues

## Technical Details

### Service Worker Caching
```javascript
// Static files cached on install
const STATIC_FILES = [
  './', './index.html', './styles.css', './dashboard.js',
  './medical-check.png', './unhealthy.png', './manifest.json',
  // Bootstrap CDN resources
];

// Dynamic caching for health data
// Network-first strategy with cache fallback
```

### Version Management
- Version displayed in header: `v1.0.0`
- Service worker version: `grq-health-v1.0.0`
- Cache versioning for updates

### Browser Support
- ✅ Chrome/Edge (full PWA support)
- ✅ Firefox (basic PWA support)
- ✅ Safari (iOS 11.3+, macOS 10.13.4+)
- ✅ Samsung Internet
- ⚠️ Limited support in older browsers

## Customization

### Changing App Colors
Update these files for different color schemes:
- `manifest.json`: `theme_color` and `background_color`
- `browserconfig.xml`: `TileColor`
- `styles.css`: Offline mode colors

### Adding New Icons
1. Replace `medical-check.png` with your new icon
2. Run the icon generation script:
   ```bash
   for size in 72 96 128 144 152 192 384 512; do 
     sips -z $size $size medical-check.png --out icons/icon-${size}x${size}.png
   done
   ```

### Updating Service Worker
1. Increment version in `sw.js` (CACHE_NAME)
2. Update version in `dashboard.js` (VERSION constant)
3. Clear browser cache to see changes

## Troubleshooting

### App Not Installing
- Ensure HTTPS is enabled (required for PWA)
- Check browser console for service worker errors
- Verify manifest.json is accessible

### Offline Mode Not Working
- Check service worker registration in browser dev tools
- Verify cache is populated (Application tab)
- Test network connectivity

### Icons Not Showing
- Verify icon files exist in `/icons/` directory
- Check manifest.json icon paths
- Clear browser cache

## Future Enhancements

### Planned Features
- Push notifications for critical health alerts
- Background sync for health data
- Offline health data editing
- Health trend analysis
- Custom health thresholds

### Performance Optimizations
- Lazy loading of host details
- Image optimization
- Bundle size reduction
- Progressive image loading

## Security Considerations

- Service worker runs in secure context (HTTPS required)
- No sensitive data cached in service worker
- Health data cached temporarily for offline viewing
- Clear cache on app updates

## Support

For issues with the PWA functionality:
1. Check browser console for errors
2. Verify network connectivity
3. Clear browser cache and reload
4. Test in different browsers
5. Check service worker status in dev tools

---

*Last updated: September 2025*
*PWA Version: 1.0.0*
