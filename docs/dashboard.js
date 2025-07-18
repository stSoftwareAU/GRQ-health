let currentFilter = 'all';
let allHosts = [];

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

function getHealthStatus(_hostname, data) {
    // Check if this is a dead machine
    if (data.death_date) {
        return 'dead';
    }
    
    // Check if this is a mobile host (don't mark as unhealthy for being offline)
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
    
    // Check for critical state (no heartbeat for 24+ hours)
    // Mobile hosts are not marked as critical for being offline
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
    const logUrl = `./${hostname}/node.log`;
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
    
    return `
        <div class="col-lg-6 col-xl-4">
            <div class="host-card ${statusClass}${mobileClass}" data-status="${healthStatus}" data-hostname="${hostname}">
                <div class="d-flex justify-content-between align-items-center mb-3">
                    <h5 class="mb-0">${emoji} ${hostname}</h5>
                    <span class="health-status ${statusClass}">${healthStatus}</span>
                </div>
                ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                <div class="row">
                    <div class="col-6">
                        <small class="text-muted">OS</small>
                        <div class="fw-bold">${data.os_info} ${data.os_version}</div>
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
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-6">
                        <small class="text-muted">Timezone</small>
                        <div class="fw-bold">${data.timezone}</div>
                    </div>
                </div>
                ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${data.info}</div></div></div>` : ''}
                <div class="last-seen">Last seen: ${data.heart_beat_ts ? formatTimestamp(data.heart_beat_ts) : 'Unknown'}</div>
                <div class="text-end mt-2">
                    <a href="${logUrl}" target="_blank" class="btn btn-sm ${data.exception_count && parseInt(data.exception_count) > 0 ? 'btn-danger' : 'btn-outline-primary'}" 
                       ${data.exception_count && parseInt(data.exception_count) > 0 ? `title="${data.exception_summary}" data-bs-toggle="tooltip" data-bs-placement="top"` : ''}>
                        <i class="bi ${data.exception_count && parseInt(data.exception_count) > 0 ? 'bi-exclamation-triangle' : 'bi-file-text'}"></i> 
                        ${data.exception_count && parseInt(data.exception_count) > 0 ? 'View Log ⚠️' : 'View Log'}
                    </a>
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
        critical: hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'critical').length
    };

    document.getElementById('totalHosts').textContent = stats.total;
    document.getElementById('healthyHosts').textContent = stats.healthy;
    document.getElementById('warningHosts').textContent = stats.warning;
    document.getElementById('criticalHosts').textContent = stats.critical;

    // Update page title and header based on overall health
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
        headerSubtitle.textContent = isHealthy ? "All hosts responding normally" : "Some hosts not responding";
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
        const priority = { critical: 5, warning: 4, healthy: 3, historical: 2, dead: 1 };
        
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
        
        // Update the card's CSS classes to reflect the new health status
        hostCard.className = `host-card ${healthStatus}${data.mobile ? ' mobile' : ''}`;
        hostCard.setAttribute('data-status', healthStatus);
        
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
        
        // Update network status
        const networkElement = hostCard.querySelector('.row:nth-child(3) .col-6:last-child .fw-bold');
        if (networkElement) {
            networkElement.textContent = data.network_status;
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
        
        // Update the View Log button
        const logButton = hostCard.querySelector('a[href*="node.log"]');
        if (logButton) {
            const hasExceptions = data.exception_count && parseInt(data.exception_count) > 0;
            logButton.className = `btn btn-sm ${hasExceptions ? 'btn-danger' : 'btn-outline-primary'}`;
            logButton.innerHTML = `<i class="bi ${hasExceptions ? 'bi-exclamation-triangle' : 'bi-file-text'}"></i> ${hasExceptions ? 'View Log ⚠️' : 'View Log'}`;
            
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