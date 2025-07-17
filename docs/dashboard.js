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

function getHealthStatus(heartbeatTs) {
    const now = Math.floor(Date.now() / 1000);
    const hoursSinceHeartbeat = (now - heartbeatTs) / 3600;
    // Handle timezone issues - if heartbeat is in the future, assume it's recent
    if (heartbeatTs > now) {
        return 'healthy';
    }
    if (hoursSinceHeartbeat <= 24) return 'healthy';
    return 'critical';
}

function createHostCard(hostname, data) {
    const healthStatus = getHealthStatus(data.heart_beat_ts);
    const statusClass = healthStatus;
    const logUrl = `./${hostname}/node.log`;
    
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
                    <h5 class="mb-0">${hostname}</h5>
                    <span class="health-status ${statusClass}">${healthStatus}</span>
                </div>
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
        healthy: hosts.filter(([_, data]) => getHealthStatus(data.heart_beat_ts) === 'healthy').length,
        warning: hosts.filter(([_, data]) => getHealthStatus(data.heart_beat_ts) === 'warning').length,
        critical: hosts.filter(([_, data]) => getHealthStatus(data.heart_beat_ts) === 'critical').length
    };

    document.getElementById('totalHosts').textContent = stats.total;
    document.getElementById('healthyHosts').textContent = stats.healthy;
    document.getElementById('warningHosts').textContent = stats.warning;
    document.getElementById('criticalHosts').textContent = stats.critical;

    // Show critical hosts section if there are any
    const criticalSection = document.getElementById('criticalSection');
    const criticalHostsList = document.getElementById('criticalHostsList');
    if (stats.critical > 0) {
        const criticalHosts = hosts.filter(([_, data]) => getHealthStatus(data.heart_beat_ts) === 'critical');
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
    const filteredHosts = allHosts.filter(([_, data]) => {
        const status = getHealthStatus(data.heart_beat_ts);
        return filter === 'all' || status === filter;
    });
    // Sort: critical first, then warning, then healthy
    filteredHosts.sort(([_, dataA], [__, dataB]) => {
        const statusA = getHealthStatus(dataA.heart_beat_ts);
        const statusB = getHealthStatus(dataB.heart_beat_ts);
        const priority = { critical: 3, warning: 2, healthy: 1 };
        return priority[statusB] - priority[statusA];
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