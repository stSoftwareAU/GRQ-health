// Version constant - this will be updated by the git hook
const VERSION = "1.0.32";

// Set page title with version
document.title = `GRQ Health Dashboard v${VERSION}`;

let currentFilter = 'all';
let allHosts = [];

// Initialize PWA functionality when DOM is loaded
document.addEventListener("DOMContentLoaded", () => {
  console.log('DOM loaded, setting version:', VERSION);
  const versionElement = document.getElementById("version");
  if (versionElement) {
    versionElement.textContent = VERSION;
  }
  
  // Check if service workers are supported, if not redirect to simple version
  checkServiceWorkerSupport();
  
  // Initialize offline indicator
  initializeOfflineIndicator();
});

function formatUptime(seconds) {
    if (seconds < 60) return `${seconds}s`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
    return `${Math.floor(seconds / 86400)}d`;
}

function formatTimestamp(timestamp) {
    const date = new Date(timestamp * 1000);
    const now = new Date();
    const diffMs = now - date;
    const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
    if (diffHours < 1) return 'Just now';
    if (diffHours < 24) return `${diffHours}h ago`;
    return `${Math.floor(diffHours / 24)}d ago`;
}

// Offline indicator functionality
function initializeOfflineIndicator() {
  // Monitor online/offline status and apply color scheme
  function updateOnlineStatus() {
    if (!navigator.onLine) {
      // Apply offline color scheme
      document.body.classList.add('offline-mode');
      showOfflineIndicator();
    } else {
      // Remove offline color scheme
      document.body.classList.remove('offline-mode');
      hideOfflineIndicator();
    }
  }
  
  // Listen for online/offline events
  window.addEventListener('online', updateOnlineStatus);
  window.addEventListener('offline', updateOnlineStatus);
  
  // Check initial status
  updateOnlineStatus();
  
  // Monitor fetch requests for cache indicators
  const originalFetch = window.fetch;
  window.fetch = function(...args) {
    const url = args[0];
    const isDataFile = typeof url === 'string' && url.includes('index.json');
    
    return originalFetch.apply(this, args)
      .then(response => {
        // Check if response was served from cache
        if (response.headers.get('X-Served-From-Cache') === 'true') {
          if (isDataFile) {
            showCacheIndicator();
            console.warn('HEALTH WARNING: Using cached data for', url);
          }
        }
        
        // Check for validation warnings
        if (response.headers.get('X-Validation-Warning') === 'CACHED-DATA') {
          showCacheIndicator();
          console.error('HEALTH ERROR: Cached data being used for health monitoring!');
        }
        
        return response;
      })
      .catch(error => {
        // If fetch fails for data files, show health error
        if (isDataFile && !navigator.onLine) {
          showHealthError('No network connection available. Cannot load health data.');
          console.error('HEALTH ERROR: Cannot load data for health monitoring:', error);
        }
        throw error;
      });
  };
}

function showOfflineIndicator() {
  // Create or update offline indicator
  let indicator = document.getElementById('offline-indicator');
  if (!indicator) {
    indicator = document.createElement('div');
    indicator.id = 'offline-indicator';
    indicator.className = 'alert alert-warning position-fixed';
    indicator.style.cssText = 'top: 10px; right: 10px; z-index: 9999; max-width: 300px;';
    document.body.appendChild(indicator);
  }
  
  indicator.innerHTML = `
    <div class="d-flex align-items-center">
      <i class="bi bi-wifi-off me-2"></i>
      <div>
        <strong>Offline Mode</strong><br>
        <small>Using cached health data</small>
      </div>
    </div>
  `;
  indicator.style.display = 'block';
}

function hideOfflineIndicator() {
  const indicator = document.getElementById('offline-indicator');
  if (indicator) {
    indicator.style.display = 'none';
  }
}

function showCacheIndicator() {
  const indicator = document.getElementById('offline-indicator');
  if (indicator) {
    indicator.className = 'alert alert-danger position-fixed';
    indicator.style.cssText = 'top: 10px; right: 10px; z-index: 9999; max-width: 400px; display: block;';
    indicator.innerHTML = `
      <div class="d-flex align-items-center">
        <i class="bi bi-exclamation-triangle me-2"></i>
        <div>
          <strong>⚠️ HEALTH WARNING ⚠️</strong><br>
          <small>Using CACHED data - health status may be OUTDATED!</small><br>
          <small>Connect to internet for real-time monitoring</small>
        </div>
      </div>
    `;
  }
}

function showHealthError(message) {
  // Create a more prominent error indicator
  const errorIndicator = document.createElement('div');
  errorIndicator.id = 'health-error';
  errorIndicator.className = 'alert alert-danger position-fixed';
  errorIndicator.style.cssText = 'top: 50%; left: 50%; transform: translate(-50%, -50%); z-index: 10000; max-width: 500px; text-align: center;';
  errorIndicator.innerHTML = `
    <div class="d-flex flex-column align-items-center">
      <i class="bi bi-exclamation-circle mb-3" style="font-size: 3rem; color: #dc3545;"></i>
      <h4 class="text-danger mb-3">Health Monitoring Unavailable</h4>
      <p class="mb-3">${message}</p>
      <button class="btn btn-primary" onclick="this.parentElement.parentElement.remove()">
        <i class="bi bi-arrow-clockwise me-1"></i> Retry
      </button>
    </div>
  `;
  
  // Remove any existing error indicator
  const existing = document.getElementById('health-error');
  if (existing) existing.remove();
  
  document.body.appendChild(errorIndicator);
}

function checkServiceWorkerSupport() {
  // Check if service workers are supported
  if (!('serviceWorker' in navigator)) {
    console.log('Service Worker not supported, redirecting to simple version');
    redirectToSimpleVersion();
    return;
  }
  
  // Additional check: try to register a test service worker to see if it actually works
  // This helps catch cases where serviceWorker exists but doesn't work properly
  try {
    // Check if we can create a service worker registration
    if (!navigator.serviceWorker.register) {
      console.log('Service Worker registration not available, redirecting to simple version');
      redirectToSimpleVersion();
      return;
    }
    
    // Check if we're in a secure context (required for service workers)
    if (!window.isSecureContext && location.protocol !== 'https:' && location.hostname !== 'localhost') {
      console.log('Not in secure context, service workers may not work properly');
      // Don't redirect here as it might work in some cases, just log a warning
    }
    
    console.log('Service Worker support detected, continuing with PWA version');
  } catch (error) {
    console.log('Service Worker support check failed, redirecting to simple version:', error);
    redirectToSimpleVersion();
  }
}

function redirectToSimpleVersion() {
  // Only redirect if we're not already on the simple version
  if (!window.location.pathname.includes('simple.html')) {
    console.log('Redirecting to simple version for better compatibility');
    window.location.href = './simple.html';
  }
}

function getHealthStatus(_hostname, data) {
    // Check if this is a dead machine
    if (data.death_date) {
        return 'dead';
    }
    
    // Check if this is a mobile host without heartbeat
    if (data.mobile && !data.heart_beat_ts) {
        // For mobile hosts without heartbeat, mark as historical
        return 'historical';
    }
    
    // For active hosts without heartbeat, mark as critical (unless mobile)
    if (!data.heart_beat_ts) {
        return 'critical';
    }
    
    const now = Math.floor(Date.now() / 1000);
    const hoursSinceHeartbeat = (now - data.heart_beat_ts) / 3600;
    
    // Handle timezone issues - if heartbeat is in the future, assume it's recent
    if (data.heart_beat_ts > now) {
        return 'healthy';
    }
    
    // Check for MIA state (mobile hosts not seen for 24+ hours)
    if (hoursSinceHeartbeat > 24 && data.mobile) {
        return 'mia';
    }
    
    // Check for critical state (no heartbeat for 24+ hours)
    // Mobile hosts are now marked as MIA instead of critical
    if (hoursSinceHeartbeat > 24 && !data.mobile) {
        return 'critical';
    }
    
    // Check for warning states
    if (hoursSinceHeartbeat <= 24) {
        // Disk usage warning (over 75% used) - applies to all hosts including mobile
        // High disk usage is bad - indicates potential storage issues
        if (data.used_disk_percent && parseFloat(data.used_disk_percent) > 75) {
            return 'warning';
        }
        
        // Config warning (missing PRIMARY_READ_URL or TRAINING_WRITE_URL)
        if (data.config_warning && data.config_warning.trim().length > 0) {
            return 'warning';
        }
        
        // CPU utilization warning (under 20% for multi-core systems) - indicates potential training issues
        // Low CPU usage on multi-core systems might indicate single-threaded training or stuck processes
        if (data.cpu_load && data.cpu_cores) {
            const cpuPercent = parseFloat(data.cpu_load.replace('%', ''));
            const coreCount = parseInt(data.cpu_cores);
            if (coreCount > 4 && cpuPercent < 20) {
                return 'warning';
            }
        }
        
        // Recent utilization warning - check 5-minute load average for recent activity
        if (data.load_averages && data.cpu_cores) {
            const loadMatch = data.load_averages.match(/(\d+\.?\d*)% \(5m\)/);
            if (loadMatch) {
                const load5mPercent = parseFloat(loadMatch[1]);
                const coreCount = parseInt(data.cpu_cores);
                // If 5-minute load average is very low on multi-core systems, might indicate recent under utilization
                if (coreCount > 4 && load5mPercent < 10) {
                    return 'warning';
                }
            }
        }
        
        // OS version warning (basic check)
        if (data.os_info && data.os_version) {
            if (data.os_info.includes('macOS') && data.os_version < '14.0') {
                return 'warning';
            }
            if (data.os_info.includes('Ubuntu') && data.os_version < '22.04') {
                return 'warning';
            }
        }
        
        // macOS version update check - compare against latest known version
        // Note: This is informational only, not a warning status
        // The visual indicator is handled in createHostCard function
        
        // Exception warning (if there are exceptions in the log)
        if (data.exception_count && parseInt(data.exception_count) > 0) {
            return 'warning';
        }
        
        return 'healthy';
    }
    
    return 'healthy';
}

function createHostCard(hostname, data) {
    const healthStatus = getHealthStatus(hostname, data);
    const statusClass = healthStatus;
    const logUrl = `./log-viewer.html?file=./${hostname}/node.log`;
    const emoji = data.emoji || '';
    const location = data.location || '';
    
    if (healthStatus === 'dead') {
        return `
            <div class="col-lg-6 col-xl-4">
                <div class="host-card dead" data-status="dead">
                    <div class="d-flex justify-content-between align-items-center mb-3">
                        <h5 class="mb-0">${emoji} ${hostname}</h5>
                        <span class="health-status dead">Dead</span>
                    </div>
                    ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                    <div class="row">
                        <div class="col-12">
                            <small class="text-muted">Death Date</small>
                            <div class="fw-bold">${data.death_date}</div>
                        </div>
                    </div>
                    ${data.os_info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">OS</small><div class="fw-bold">${data.os_info}</div></div></div>` : ''}
                    ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${data.info}</div></div></div>` : ''}
                    <div class="text-center mt-3">
                        <span class="badge bg-secondary">Historical Record</span>
                    </div>
                </div>
            </div>
        `;
    }
    
    if (healthStatus === 'historical') {
        // MacBook Airs and other historical hosts
        return `
            <div class="col-lg-6 col-xl-4">
                <div class="host-card historical" data-status="historical">
                    <div class="d-flex justify-content-between align-items-center mb-3">
                        <h5 class="mb-0">${emoji} ${hostname}</h5>
                        <span class="health-status historical">Historical</span>
                    </div>
                    ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                    <div class="row">
                        <div class="col-6">
                            <small class="text-muted">OS</small>
                            <div class="fw-bold">${data.os_info}</div>
                        </div>
                        <div class="col-6">
                            <small class="text-muted">Last Seen</small>
                            <div class="fw-bold">${data.last_seen || 'Unknown'}</div>
                        </div>
                    </div>
                    ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${data.info}</div></div></div>` : ''}
                    ${data.sample_rate ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Sample Rate</small><div class="fw-bold">${data.sample_rate}</div></div></div>` : ''}
                    <div class="text-center mt-3">
                        <span class="badge bg-info">MacBook Air</span>
                    </div>
                </div>
            </div>
        `;
    }
    
    if (healthStatus === 'mia') {
        // Mobile devices that are Off the Grid (not seen for 24+ hours)
        const miaEmoji = '🏖️'; // Globe emoji for Off the Grid
        return `
            <div class="col-lg-6 col-xl-4">
                <div class="host-card mia" data-status="mia">
                    <div class="d-flex justify-content-between align-items-center mb-3">
                        <h5 class="mb-0">${miaEmoji} ${hostname}</h5>
                        <span class="health-status mia">Off the Grid</span>
                    </div>
                    ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                    <div class="row">
                        <div class="col-6">
                            <small class="text-muted">OS</small>
                            <div class="fw-bold">${data.os_info} ${data.os_version}</div>
                        </div>
                        <div class="col-6">
                            <small class="text-muted">Last Seen</small>
                            <div class="fw-bold">${data.heart_beat_ts ? formatTimestamp(data.heart_beat_ts) : 'Unknown'}</div>
                        </div>
                    </div>
                    ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${data.info}</div></div></div>` : ''}
                    <div class="text-center mt-3">
                        <span class="badge bg-info">Off the Grid</span>
                    </div>
                </div>
            </div>
        `;
    }
    
    // Active hosts with health data
    // Format disk space display - consistent with memory/CPU format
    let diskDisplay = data.used_disk_percent;
    if (data.used_disk_percent && data.used_disk_percent !== 'unknown') {
        diskDisplay = `${data.used_disk_percent}% used`;
        // Add total disk info if available
        if (data.total_disk_gb && data.total_disk_gb !== 'unknown' && data.total_disk_gb !== '0' && parseFloat(data.total_disk_gb) > 0) {
            diskDisplay += ` of ${data.total_disk_gb}GB`;
        }
    }
    
    // Format CPU usage display
    let cpuDisplay = data.cpu_load;
    if (data.cpu_load && data.cpu_load !== 'unknown') {
        if (data.cpu_load.includes('%')) {
            cpuDisplay = data.cpu_load;
        } else {
            // Convert load average to percentage if it's a number
            const loadValue = parseFloat(data.cpu_load);
            if (!isNaN(loadValue)) {
                cpuDisplay = `${loadValue}%`;
            }
        }
    }
    
    // Add CPU cores and model info if available
    if (data.cpu_cores && data.cpu_cores !== 'unknown' && data.cpu_cores !== '0') {
        cpuDisplay += ` (${data.cpu_cores} cores`;
        if (data.cpu_model && data.cpu_model !== 'unknown') {
            cpuDisplay += `, ${data.cpu_model}`;
        }
        cpuDisplay += ')';
    }
    
    // Machine type is now displayed in the header
    
    // Format memory display
    let memDisplay = data.mem_usage_percent;
    if (data.mem_usage_percent && data.mem_usage_percent !== 'unknown') {
        memDisplay = `${data.mem_usage_percent}%`;
        // Add total memory info if available
        if (data.total_mem_gb && data.total_mem_gb !== 'unknown' && data.total_mem_gb !== '0' && parseFloat(data.total_mem_gb) > 0) {
            memDisplay += ` of ${data.total_mem_gb}GB`;
        }
    }
    
    // Add mobile class if host is marked as mobile
    const mobileClass = data.mobile ? ' mobile' : '';
    
    // Check if macOS version is outdated
    let outdatedMacClass = '';
    if (data.os_info && data.os_info.includes('macOS') && data.os_version) {
        const latestMacOSVersion = allHosts
            .filter(([_, hostData]) => hostData.os_info && hostData.os_info.includes('macOS') && hostData.os_version)
            .map(([_, hostData]) => hostData.os_version)
            .sort()
            .pop();
        
        if (latestMacOSVersion && data.os_version < latestMacOSVersion) {
            outdatedMacClass = ' outdated-macos';
        }
    }
    
    return `
        <div class="col-lg-6 col-xl-4">
            <div class="host-card ${statusClass}${mobileClass}${outdatedMacClass}" data-status="${healthStatus}" data-hostname="${hostname}">
                <div class="d-flex justify-content-between align-items-center mb-3">
                    <h5 class="mb-0 d-flex align-items-center">
                        ${emoji} ${hostname}
                        ${data.machine_type && data.machine_type !== 'unknown' && data.machine_type !== '' ? `<span class="badge bg-secondary ms-2" style="font-size: 0.7rem;">${data.machine_type}</span>` : ''}
                    </h5>
                    <span class="health-status ${statusClass}">${healthStatus}</span>
                </div>
                ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                <div class="row">
                    <div class="col-6">
                        <small class="text-muted">OS</small>
                        <div class="fw-bold">
                            ${data.os_info} ${data.os_version}
                            ${outdatedMacClass ? '<span class="badge bg-warning text-white ms-2" title="Update available"><i class="bi bi-arrow-up-circle"></i> Update</span>' : ''}
                        </div>
                    </div>
                    <div class="col-6">
                        <small class="text-muted">Uptime</small>
                        <div class="fw-bold">${formatUptime(data.uptime)}</div>
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-6">
                        <small class="text-muted">Disk Usage</small>
                        <div class="fw-bold">${diskDisplay}</div>
                    </div>
                    <div class="col-6">
                        <small class="text-muted">Memory</small>
                        <div class="fw-bold">${memDisplay}</div>
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-6">
                        <small class="text-muted">CPU Load</small>
                        <div class="fw-bold">${cpuDisplay}</div>
                        ${data.cpu_breakdown ? `<small class="text-muted">${data.cpu_breakdown}</small>` : ''}
                        ${data.load_averages ? `<small class="text-muted">Recent: ${data.load_averages}</small>` : ''}
                    </div>
                    <div class="col-6">
                        <small class="text-muted">Network</small>
                        <div class="fw-bold">${data.network_status}</div>
                        ${data.ip_addresses ? `<small class="text-muted">${data.ip_addresses}</small>` : ''}
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-6">
                        <small class="text-muted">Timezone</small>
                        <div class="fw-bold">${data.timezone}</div>
                    </div>
                </div>
                ${data.config_warning ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Config</small><div class="fw-bold text-warning">${data.config_warning}</div></div></div>` : ''}
                ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${data.info}</div></div></div>` : ''}
                <div class="last-seen">Last seen: ${data.heart_beat_ts ? formatTimestamp(data.heart_beat_ts) : 'Unknown'}</div>
                <div class="d-flex justify-content-center align-items-center mt-2 position-relative">
                    <div class="text-center">
                        ${data.version ? `<small class="text-muted" style="font-size: 0.6rem; opacity: 0.6;" title="Health script version">v${data.version}</small>` : ''}
                    </div>
                    <div class="position-absolute" style="right: 0;">
                        <a href="${logUrl}" class="btn btn-sm ${data.exception_count && parseInt(data.exception_count) > 0 ? 'btn-danger' : 'btn-outline-primary'}" 
                           ${data.exception_count && parseInt(data.exception_count) > 0 ? `title="${data.exception_summary}" data-bs-toggle="tooltip" data-bs-placement="top"` : ''}>
                            <i class="bi ${data.exception_count && parseInt(data.exception_count) > 0 ? 'bi-exclamation-triangle' : 'bi-file-text'}"></i> 
                            ${data.exception_count && parseInt(data.exception_count) > 0 ? 'View Log ⚠️' : 'View Log'}
                        </a>
                    </div>
                </div>
            </div>
        </div>
    `;
    }

function updateStats(hosts) {
    const stats = {
        total: hosts.length,
        healthy: hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'healthy').length,
        warning: hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'warning').length,
        critical: hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'critical').length,
        mia: hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'mia').length
    };

    document.getElementById('totalHosts').textContent = stats.total;
    document.getElementById('healthyHosts').textContent = stats.healthy;
    document.getElementById('warningHosts').textContent = stats.warning;
    document.getElementById('criticalHosts').textContent = stats.critical;

    // Update page title and header based on overall health
    // Only count critical devices as unhealthy - MIA devices are just missing, not unhealthy
    const isHealthy = stats.critical === 0;
    const healthStatus = isHealthy ? "GRQ Healthy" : "GRQ Unhealthy";
    document.title = healthStatus;
    
    // Update favicon based on health
    const favicon = document.querySelector('link[rel="icon"]');
    if (favicon) {
        favicon.href = isHealthy ? './medical-check.png' : './unhealthy.png';
    }
    
    // Update the header title
    const headerTitle = document.querySelector('.header h1');
    if (headerTitle) {
        headerTitle.innerHTML = `<i class="bi bi-display"></i> ${healthStatus}`;
    }
    
    // Update the header subtitle
    const headerSubtitle = document.querySelector('.header p');
    if (headerSubtitle) {
        if (stats.critical > 0) {
            headerSubtitle.textContent = "Some hosts not responding";
        } else if (stats.mia > 0) {
            headerSubtitle.textContent = `All hosts responding normally (${stats.mia} mobile device${stats.mia > 1 ? 's' : ''} off the grid)`;
        } else {
            headerSubtitle.textContent = "All hosts responding normally";
        }
    }

    // Show critical hosts section if there are any
    const criticalSection = document.getElementById('criticalSection');
    const criticalHostsList = document.getElementById('criticalHostsList');
    if (stats.critical > 0) {
        const criticalHosts = hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'critical');
        const criticalHtml = criticalHosts.map(([hostname, data]) => {
            if (data.heart_beat_ts) {
                const hoursSince = Math.floor((Math.floor(Date.now() / 1000) - data.heart_beat_ts) / 3600);
                return `<div class="critical-host-item">
                    <strong>${hostname}</strong> - Last seen: ${formatTimestamp(data.heart_beat_ts)} (${hoursSince} hours ago)
                </div>`;
            } else {
                return `<div class="critical-host-item">
                    <strong>${hostname}</strong> - No heartbeat data available
                </div>`;
            }
        }).join('');
        criticalHostsList.innerHTML = criticalHtml;
        criticalSection.style.display = 'block';
    } else {
        criticalSection.style.display = 'none';
    }

    // Show MIA hosts section if there are any
    const miaSection = document.getElementById('miaSection');
    const miaHostsList = document.getElementById('miaHostsList');

    if (stats.mia > 0) {
        const miaHosts = hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'mia');
        const miaHtml = miaHosts.map(([hostname, data]) => {
            if (data.heart_beat_ts) {
                const hoursSince = Math.floor((Math.floor(Date.now() / 1000) - data.heart_beat_ts) / 3600);
                return `<div class="mia-host-item">
                    <strong>${hostname}</strong> - Last seen: ${formatTimestamp(data.heart_beat_ts)} (${hoursSince} hours ago)
                </div>`;
            } else {
                return `<div class="mia-host-item">
                    <strong>${hostname}</strong> - No heartbeat data available
                </div>`;
            }
        }).join('');
        miaHostsList.innerHTML = miaHtml;
        miaSection.style.display = 'block';
    } else {
        miaSection.style.display = 'none';
    }

    // Show warning hosts section if there are any
    const warningSection = document.getElementById('warningSection');
    const warningHostsList = document.getElementById('warningHostsList');
    if (stats.warning > 0) {
        const warningHosts = hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'warning');
        const warningHtml = warningHosts.map(([hostname, data]) => {
            let warningReason = '';
            if (data.used_disk_percent && parseFloat(data.used_disk_percent) > 75) {
                warningReason += `High disk usage: ${data.used_disk_percent}%`;
            }
            if (data.config_warning) {
                if (warningReason) warningReason += ', ';
                warningReason += data.config_warning;
            }
            if (data.cpu_load && data.cpu_cores) {
                const cpuPercent = parseFloat(data.cpu_load.replace('%', ''));
                const coreCount = parseInt(data.cpu_cores);
                if (coreCount > 4 && cpuPercent < 20) {
                    if (warningReason) warningReason += ', ';
                    warningReason += `Low CPU utilization: ${data.cpu_load} (${coreCount} cores)`;
                }
            }
            if (data.load_averages && data.cpu_cores) {
                const loadMatch = data.load_averages.match(/(\d+\.?\d*)% \(5m\)/);
                if (loadMatch) {
                    const load5mPercent = parseFloat(loadMatch[1]);
                    const coreCount = parseInt(data.cpu_cores);
                    if (coreCount > 4 && load5mPercent < 10) {
                        if (warningReason) warningReason += ', ';
                        warningReason += `Low recent utilization: ${load5mPercent}% (5m avg)`;
                    }
                }
            }
            if (data.os_info && data.os_version) {
                if ((data.os_info.includes('macOS') && data.os_version < '14.0') || 
                    (data.os_info.includes('Ubuntu') && data.os_version < '22.04')) {
                    if (warningReason) warningReason += ', ';
                    warningReason += `OS version: ${data.os_version}`;
                }
            }
            
            // macOS version updates are now informational only, not warnings
            // The visual indicators are handled in the card display
            if (data.exception_count && parseInt(data.exception_count) > 0) {
                if (warningReason) warningReason += ', ';
                warningReason += `Stack traces: ${data.exception_summary}`;
            }
            return `<div class="warning-host-item">
                <strong>${hostname}</strong> - ${warningReason}
            </div>`;
        }).join('');
        warningHostsList.innerHTML = warningHtml;
        warningSection.style.display = 'block';
    } else {
        warningSection.style.display = 'none';
    }
}

function filterHosts(filter, event) {
    currentFilter = filter;
    // Update stat cards
    document.querySelectorAll('.stat-card').forEach(card => {
        card.classList.remove('active');
    });
    if (event && event.target) {
        // Find the clicked stat card
        const statCard = event.target.closest('.stat-card');
        if (statCard) {
            statCard.classList.add('active');
        }
    }
    // Filter hosts
    const filteredHosts = allHosts.filter(([hostname, data]) => {
        const status = getHealthStatus(hostname, data);
        return filter === 'all' || status === filter;
    });
    // Sort: critical first, then warning, then healthy, then historical, then dead, then by last seen (most recent first)
    filteredHosts.sort(([hostnameA, dataA], [hostnameB, dataB]) => {
        const statusA = getHealthStatus(hostnameA, dataA);
        const statusB = getHealthStatus(hostnameB, dataB);
        const priority = { critical: 6, mia: 5, warning: 4, healthy: 3, historical: 2, dead: 1 };
        
        // First sort by health status
        const statusDiff = priority[statusB] - priority[statusA];
        if (statusDiff !== 0) {
            return statusDiff;
        }
        
        // Then sort by last seen (most recent first)
        // Handle undefined heart_beat_ts by treating them as very old
        const tsA = dataA.heart_beat_ts || 0;
        const tsB = dataB.heart_beat_ts || 0;
        return tsB - tsA;
    });
    displayHosts(filteredHosts);
}

function displayHosts(hosts) {
    const content = document.getElementById('content');
    if (hosts.length === 0) {
        content.innerHTML = '<div class="loading">No hosts found matching the current filter.</div>';
        return;
    }
    const hostsHtml = hosts.map(([hostname, data]) => createHostCard(hostname, data)).join('');
    content.innerHTML = `<div class="row">${hostsHtml}</div>`;
}

function updateHostCard(hostname, data) {
    // Find existing host card
    const hostCard = document.querySelector(`[data-hostname="${hostname}"]`);
    if (hostCard) {
        // Add a subtle highlight effect
        hostCard.style.transition = 'background-color 0.3s ease';
        hostCard.style.backgroundColor = 'rgba(40, 167, 69, 0.1)';
        setTimeout(() => {
            hostCard.style.backgroundColor = '';
        }, 1000);
        
        // Update individual elements instead of replacing the entire card
        const healthStatus = getHealthStatus(hostname, data);
        
        // Update health status
        const statusElement = hostCard.querySelector('.health-status');
        if (statusElement) {
            statusElement.className = `health-status ${healthStatus}`;
            statusElement.textContent = healthStatus;
        }
        
        // Check if macOS version is outdated for the updated card
        let outdatedMacClass = '';
        if (data.os_info && data.os_info.includes('macOS') && data.os_version) {
            const latestMacOSVersion = allHosts
                .filter(([_, hostData]) => hostData.os_info && hostData.os_info.includes('macOS') && hostData.os_version)
                .map(([_, hostData]) => hostData.os_version)
                .sort()
                .pop();
            
            if (latestMacOSVersion && data.os_version < latestMacOSVersion) {
                outdatedMacClass = ' outdated-macos';
            }
        }
        
        // Update the card's CSS classes to reflect the new health status
        hostCard.className = `host-card ${healthStatus}${data.mobile ? ' mobile' : ''}${outdatedMacClass}`;
        hostCard.setAttribute('data-status', healthStatus);
        
        // Update hostname with machine type badge (version moved to bottom-left)
        const hostnameElement = hostCard.querySelector('h5.mb-0');
        if (hostnameElement) {
            const emoji = hostCard.querySelector('h5.mb-0').textContent.match(/^[^\s]+/)?.[0] || '';
            hostnameElement.className = 'mb-0 d-flex align-items-center';
            hostnameElement.innerHTML = `${emoji} ${hostname}${data.machine_type && data.machine_type !== 'unknown' && data.machine_type !== '' ? `<span class="badge bg-secondary ms-2" style="font-size: 0.7rem;">${data.machine_type}</span>` : ''}`;
        }
        
        // Update OS version display with update badge if needed
        const osElement = hostCard.querySelector('.row:first-child .col-6:first-child .fw-bold');
        if (osElement) {
            osElement.innerHTML = `${data.os_info} ${data.os_version}${outdatedMacClass ? '<span class="badge bg-warning text-white ms-2" title="Update available"><i class="bi bi-arrow-up-circle"></i> Update</span>' : ''}`;
        }
        
        // Update uptime
        const uptimeElement = hostCard.querySelector('.row:first-child .col-6:last-child .fw-bold');
        if (uptimeElement) {
            uptimeElement.textContent = formatUptime(data.uptime);
        }
        
        // Update disk usage
        const diskElement = hostCard.querySelector('.row:nth-child(2) .col-6:first-child .fw-bold');
        if (diskElement) {
            let diskDisplay = data.used_disk_percent;
            if (data.used_disk_percent && data.used_disk_percent !== 'unknown') {
                diskDisplay = `${data.used_disk_percent}% used`;
                if (data.total_disk_gb && data.total_disk_gb !== 'unknown' && data.total_disk_gb !== '0' && parseFloat(data.total_disk_gb) > 0) {
                    diskDisplay += ` of ${data.total_disk_gb}GB`;
                }
            }
            diskElement.textContent = diskDisplay;
        }
        
        // Update memory
        const memElement = hostCard.querySelector('.row:nth-child(2) .col-6:last-child .fw-bold');
        if (memElement) {
            let memDisplay = data.mem_usage_percent;
            if (data.mem_usage_percent && data.mem_usage_percent !== 'unknown') {
                memDisplay = `${data.mem_usage_percent}%`;
                if (data.total_mem_gb && data.total_mem_gb !== 'unknown' && data.total_mem_gb !== '0' && parseFloat(data.total_mem_gb) > 0) {
                    memDisplay += ` of ${data.total_mem_gb}GB`;
                }
            }
            memElement.textContent = memDisplay;
        }
        
        // Update CPU load
        const cpuElement = hostCard.querySelector('.row:nth-child(3) .col-6:first-child .fw-bold');
        if (cpuElement) {
            let cpuDisplay = data.cpu_load;
            if (data.cpu_load && data.cpu_load !== 'unknown') {
                if (data.cpu_load.includes('%')) {
                    cpuDisplay = data.cpu_load;
                } else {
                    const loadValue = parseFloat(data.cpu_load);
                    if (!isNaN(loadValue)) {
                        cpuDisplay = `${loadValue}%`;
                    }
                }
            }
            
            if (data.cpu_cores && data.cpu_cores !== 'unknown' && data.cpu_cores !== '0') {
                cpuDisplay += ` (${data.cpu_cores} cores`;
                if (data.cpu_model && data.cpu_model !== 'unknown') {
                    cpuDisplay += `, ${data.cpu_model}`;
                }
                cpuDisplay += ')';
            }
            
            cpuElement.textContent = cpuDisplay;
        }
        
        // Update network status and IP addresses
        const networkElement = hostCard.querySelector('.row:nth-child(3) .col-6:last-child .fw-bold');
        if (networkElement) {
            networkElement.textContent = data.network_status;
        }
        
        // Update IP addresses
        const networkContainer = hostCard.querySelector('.row:nth-child(3) .col-6:last-child');
        if (networkContainer) {
            // Remove existing IP address display
            const existingIpDisplay = networkContainer.querySelector('small.text-muted:last-child');
            if (existingIpDisplay && existingIpDisplay.textContent.includes('WiFi:') || existingIpDisplay.textContent.includes('Eth:')) {
                existingIpDisplay.remove();
            }
            
            // Add new IP address display if available
            if (data.ip_addresses) {
                const ipDisplay = document.createElement('small');
                ipDisplay.className = 'text-muted';
                ipDisplay.textContent = data.ip_addresses;
                networkContainer.appendChild(ipDisplay);
            }
        }
        
        // Update timezone
        const timezoneElement = hostCard.querySelector('.row:nth-child(4) .col-6:first-child .fw-bold');
        if (timezoneElement) {
            timezoneElement.textContent = data.timezone;
        }
        
        // Update last seen
        const lastSeenElement = hostCard.querySelector('.last-seen');
        if (lastSeenElement) {
            lastSeenElement.textContent = `Last seen: ${data.heart_beat_ts ? formatTimestamp(data.heart_beat_ts) : 'Unknown'}`;
        }
        
        // Update version badge (centered on same row as View Log button)
        const versionContainer = hostCard.querySelector('.d-flex.justify-content-center.align-items-center.mt-2.position-relative > div:first-child');
        if (versionContainer) {
            versionContainer.innerHTML = data.version ? `<small class="text-muted" style="font-size: 0.6rem; opacity: 0.6;" title="Health script version">v${data.version}</small>` : '';
        }
        
        // Update the View Log button
        const logButton = hostCard.querySelector('a[href*="node.log"]');
        if (logButton) {
            const hasExceptions = data.exception_count && parseInt(data.exception_count) > 0;
            logButton.className = `btn btn-sm ${hasExceptions ? 'btn-danger' : 'btn-outline-primary'}`;
            logButton.innerHTML = `<i class="bi ${hasExceptions ? 'bi-exclamation-triangle' : 'bi-file-text'}"></i> ${hasExceptions ? 'View Log ⚠️' : 'View Log'}`;
            // Remove target="_blank" to open in same tab for better mobile experience
            logButton.removeAttribute('target');
            logButton.removeAttribute('rel');
            
            if (hasExceptions) {
                logButton.setAttribute('title', data.exception_summary);
                logButton.setAttribute('data-bs-toggle', 'tooltip');
                logButton.setAttribute('data-bs-placement', 'top');
            } else {
                logButton.removeAttribute('title');
                logButton.removeAttribute('data-bs-toggle');
                logButton.removeAttribute('data-bs-placement');
            }
        }
        
        // Reinitialize tooltips for the updated card
        initializeTooltips();
    }
}

async function loadData() {
    const content = document.getElementById('content');
    content.innerHTML = '<div class="loading">Loading health data...</div>';
    try {
        // Add timestamp to force fresh fetch
        const timestamp = new Date().getTime();
        const response = await fetch(`./index.json?t=${timestamp}`);
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        const data = await response.json();
        
        // Convert to array of [hostname, data] pairs
        allHosts = Object.entries(data);
        
        // Store current data for future comparisons
        previousHosts.clear();
        allHosts.forEach(([hostname, hostData]) => {
            previousHosts.set(hostname, JSON.stringify(hostData));
        });
        
        // Reset the full refresh timer
        lastFullRefresh = Date.now();
        
        updateStats(allHosts);
        filterHosts(currentFilter);
        initializeTooltips();
    } catch (error) {
        console.error('Error loading data:', error);
        content.innerHTML = `
            <div class="error">
                <h3>Error Loading Data</h3>
                <p>Failed to load health data: ${error.message}</p>
                <p>Make sure the index.json file exists and is accessible.</p>
            </div>
        `;
    }
}

async function loadDataIncremental() {
    try {
        // Add timestamp to force fresh fetch
        const timestamp = new Date().getTime();
        const response = await fetch(`./index.json?t=${timestamp}`);
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        const data = await response.json();
        
        // Convert to array of [hostname, data] pairs
        const newHosts = Object.entries(data);
        
        // Check for structural changes that require full refresh
        const currentHostnames = new Set(allHosts.map(([hostname]) => hostname));
        const newHostnames = new Set(newHosts.map(([hostname]) => hostname));
        
        // Check if hosts were added or removed
        const hostsAdded = newHosts.length > allHosts.length;
        const hostsRemoved = newHosts.length < allHosts.length;
        const hostnamesChanged = newHosts.some(([hostname]) => !currentHostnames.has(hostname)) ||
                                allHosts.some(([hostname]) => !newHostnames.has(hostname));
        
        // Debug logging
        console.log('Incremental update check:', {
            currentHosts: allHosts.length,
            newHosts: newHosts.length,
            hostsAdded,
            hostsRemoved,
            hostnamesChanged,
            currentHostnames: Array.from(currentHostnames),
            newHostnames: Array.from(newHostnames)
        });
        
        // If structural changes detected, do full refresh
        if (hostsAdded || hostsRemoved || hostnamesChanged) {
            console.log('Structural changes detected, doing full refresh');
            loadData();
            return;
        }
        
        // Check for data changes in existing hosts
        let hasChanges = false;
        const changedHosts = [];
        
        newHosts.forEach(([hostname, hostData]) => {
            const currentDataStr = JSON.stringify(hostData);
            const previousDataStr = previousHosts.get(hostname);
            
            if (previousDataStr !== currentDataStr) {
                changedHosts.push([hostname, hostData]);
                hasChanges = true;
            }
        });
        
        if (hasChanges) {
            // Update the global hosts array
            allHosts = newHosts;
            
            // Update stored data for next comparison
            previousHosts.clear();
            allHosts.forEach(([hostname, hostData]) => {
                previousHosts.set(hostname, JSON.stringify(hostData));
            });
            
            // Update stats
            updateStats(allHosts);
            
            // Update individual changed cards if they're currently visible
            changedHosts.forEach(([hostname, hostData]) => {
                updateHostCard(hostname, hostData);
            });
            
            // Add visual feedback for changes
            showUpdateIndicator();
        }
    } catch (error) {
        console.error('Error loading incremental data:', error);
        // Fall back to full reload on error
        loadData();
    }
}

function initializeTooltips() {
    // Initialize Bootstrap tooltips for mobile-friendly behavior
    const tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
    tooltipTriggerList.forEach(function (tooltipTriggerEl) {
        // Destroy existing tooltip if it exists
        const existingTooltip = bootstrap.Tooltip.getInstance(tooltipTriggerEl);
        if (existingTooltip) {
            existingTooltip.dispose();
        }
        
        // Create new tooltip with mobile-friendly settings
        new bootstrap.Tooltip(tooltipTriggerEl, {
            trigger: 'hover focus', // Show on hover and focus (for mobile)
            delay: { show: 500, hide: 100 }, // Slight delay for mobile
            container: 'body' // Ensure tooltip is positioned correctly
        });
    });
}

function showUpdateIndicator() {
    // Create or update a subtle update indicator
    let indicator = document.getElementById('update-indicator');
    if (!indicator) {
        indicator = document.createElement('div');
        indicator.id = 'update-indicator';
        indicator.style.cssText = `
            position: fixed;
            top: 10px;
            right: 10px;
            background: rgba(40, 167, 69, 0.9);
            color: white;
            padding: 8px 12px;
            border-radius: 4px;
            font-size: 12px;
            z-index: 1000;
            opacity: 0;
            transition: opacity 0.3s ease;
        `;
        document.body.appendChild(indicator);
    }
    
    indicator.textContent = 'Updated';
    indicator.style.opacity = '1';
    
    // Hide after 2 seconds
    setTimeout(() => {
        indicator.style.opacity = '0';
    }, 2000);
}



// Store previous data for comparison
const previousHosts = new Map();
let lastFullRefresh = Date.now();

// Load data on page load
document.addEventListener('DOMContentLoaded', loadData);

// Auto-refresh every 60 seconds with incremental updates
setInterval(() => {
    // Force full refresh if no updates for 5 minutes
    const timeSinceLastRefresh = Date.now() - lastFullRefresh;
    if (timeSinceLastRefresh > 5 * 60 * 1000) { // 5 minutes
        console.log('No updates detected for 5 minutes, forcing full refresh');
        loadData();
        return;
    }
    loadDataIncremental();
}, 60000); 