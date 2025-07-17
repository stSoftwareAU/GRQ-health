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

function getHealthStatus(hostname, data) {
    // Check if this is a dead machine
    if (data.death_date) {
        return 'dead';
    }
    
    // Check if this is a MacBook Air (don't mark as unhealthy for being offline)
    if (hostname === "Tina's" || hostname === "Nigel's") {
        // For MacBook Airs, only mark as critical if offline for more than 7 days
        if (!data.heart_beat_ts) {
            return 'historical';
        }
        const now = Math.floor(Date.now() / 1000);
        const hoursSinceHeartbeat = (now - data.heart_beat_ts) / 3600;
        if (hoursSinceHeartbeat > 168) { // 7 days
            return 'critical';
        }
        return 'historical';
    }
    
    // For active hosts, check heartbeat
    if (!data.heart_beat_ts) {
        return 'unknown';
    }
    
    const now = Math.floor(Date.now() / 1000);
    const hoursSinceHeartbeat = (now - data.heart_beat_ts) / 3600;
    
    // Handle timezone issues - if heartbeat is in the future, assume it's recent
    if (data.heart_beat_ts > now) {
        return 'healthy';
    }
    
    // Check for critical state (no heartbeat for 24+ hours)
    if (hoursSinceHeartbeat > 24) {
        return 'critical';
    }
    
    // Check for warning states
    if (hoursSinceHeartbeat <= 24) {
        // Disk usage warning (over 75%)
        if (data.disk_usage_percent && parseFloat(data.disk_usage_percent) > 75) {
            return 'warning';
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
    // Format disk space display
    let diskDisplay = data.free_disk_space;
    if (data.free_disk_space && data.free_disk_space !== 'unknown') {
        diskDisplay = `${data.free_disk_space}GB`;
        if (data.disk_usage_percent && data.disk_usage_percent !== '0' && data.disk_usage_percent !== 0) {
            diskDisplay += ` (${data.disk_usage_percent}% used)`;
        }
    }
    
    // Format CPU load display
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
    
    // Format memory display
    let memDisplay = data.mem_usage_percent;
    if (data.mem_usage_percent && data.mem_usage_percent !== 'unknown') {
        memDisplay = `${data.mem_usage_percent}%`;
    }
    
    return `
        <div class="col-lg-6 col-xl-4">
            <div class="host-card ${statusClass}" data-status="${healthStatus}">
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
                        <small class="text-muted">Free Disk</small>
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
                    </div>
                    <div class="col-6">
                        <small class="text-muted">Network</small>
                        <div class="fw-bold">${data.network_status}</div>
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-12">
                        <small class="text-muted">Timezone</small>
                        <div class="fw-bold">${data.timezone}</div>
                    </div>
                </div>
                ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${data.info}</div></div></div>` : ''}
                <div class="last-seen">Last seen: ${formatTimestamp(data.heart_beat_ts)}</div>
                <div class="text-end mt-2">
                    <a href="${logUrl}" target="_blank" class="btn btn-sm btn-outline-primary">
                        <i class="bi bi-file-text"></i> View Log
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

    // Update page title based on overall health
    const isHealthy = stats.critical === 0;
    document.title = isHealthy ? "GRQ Healthy" : "GRQ Unhealthy";

    // Show critical hosts section if there are any
    const criticalSection = document.getElementById('criticalSection');
    const criticalHostsList = document.getElementById('criticalHostsList');
    if (stats.critical > 0) {
        const criticalHosts = hosts.filter(([hostname, data]) => getHealthStatus(hostname, data) === 'critical');
        const criticalHtml = criticalHosts.map(([hostname, data]) => {
            const hoursSince = Math.floor((Math.floor(Date.now() / 1000) - data.heart_beat_ts) / 3600);
            return `<div class="critical-host-item">
                <strong>${hostname}</strong> - Last seen: ${formatTimestamp(data.heart_beat_ts)} (${hoursSince} hours ago)
            </div>`;
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
            if (data.disk_usage_percent && parseFloat(data.disk_usage_percent) > 75) {
                warningReason += `Disk usage: ${data.disk_usage_percent}%`;
            }
            if (data.os_info && data.os_version) {
                if ((data.os_info.includes('macOS') && data.os_version < '14.0') || 
                    (data.os_info.includes('Ubuntu') && data.os_version < '22.04')) {
                    if (warningReason) warningReason += ', ';
                    warningReason += `OS version: ${data.os_version}`;
                }
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
    // Sort: critical first, then warning, then healthy, then by last seen (most recent first)
    filteredHosts.sort(([hostnameA, dataA], [hostnameB, dataB]) => {
        const statusA = getHealthStatus(hostnameA, dataA);
        const statusB = getHealthStatus(hostnameB, dataB);
        const priority = { critical: 3, warning: 2, healthy: 1 };
        
        // First sort by health status
        const statusDiff = priority[statusB] - priority[statusA];
        if (statusDiff !== 0) {
            return statusDiff;
        }
        
        // Then sort by last seen (most recent first)
        return dataB.heart_beat_ts - dataA.heart_beat_ts;
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
        
        updateStats(allHosts);
        filterHosts(currentFilter);
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

// Load data on page load
document.addEventListener('DOMContentLoaded', loadData);

// Auto-refresh every 60 seconds
setInterval(loadData, 60000); 