// Version constant - this will be updated by the git hook
const VERSION = "1.1.14";

// Set page title with version
document.title = `GRQ Health Dashboard v${VERSION}`;

let currentFilter = 'all';
let allHosts = [];
let repoHealthData = { repos: [] };
let lastRepoRefresh = 0;
// Issue #49: Track disk warning state per host for hysteresis
const diskWarningState = {};

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

// Named constants for health thresholds — single source of truth (Issue #35)
const THRESHOLDS = {
    IDLE_MIN_CORES: 4,        // Only check idle status on machines with more than this many cores
    IDLE_LOAD_1M: 15,         // 1-minute load average threshold for idle detection (%)
    IDLE_LOAD_5M: 15,         // 5-minute load average threshold for idle detection (%)
    IDLE_LOAD_15M: 20,        // 15-minute load average threshold for idle detection (%)
    IDLE_HIGH_LOAD: 50,       // Load above this indicates active work (recently started/stopped)
    DISK_WARNING_PERCENT: 90, // Disk usage at or above this triggers a warning (Issue #131)
    DISK_WARNING_CLEAR_PERCENT: 87, // Disk usage must drop to or below this to clear warning (hysteresis)
    HEARTBEAT_CRITICAL_HOURS: 24, // Hours without heartbeat before marking host critical
    USER_STALE_DEFAULT_HOURS: 24, // Default hours before a user is marked stale (3x the 8h heartbeat threshold)
    MACOS_MIN_VERSION: '14.0',    // macOS versions below this trigger a warning
    UBUNTU_MIN_VERSION: '22.04'   // Ubuntu versions below this trigger a warning
};

function formatUptime(seconds) {
    if (seconds < 60) return `${seconds}s`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
    if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
    return `${Math.floor(seconds / 86400)}d`;
}

function formatTimestamp(timestamp) {
    if (!timestamp || Number.isNaN(timestamp) || timestamp <= 0) {
        return 'Unknown';
    }
    const date = new Date(timestamp * 1000);
    const now = new Date();
    const diffMs = now - date;
    const diffHours = Math.floor(diffMs / (1000 * 60 * 60));
    if (diffHours < 1) return 'Just now';
    if (diffHours < 24) return `${diffHours}h ago`;
    const days = Math.floor(diffHours / 24);
    const hoursRemainder = diffHours % 24;
    if (hoursRemainder === 0) return `${days}d ago`;
    return `${days}d ${hoursRemainder}h ago`;
}

function sanitizeUserSlug(user) {
    const raw = String(user || 'unknown');
    const slug = raw.replace(/\s+/g, '_').replace(/[^a-zA-Z0-9_-]/g, '');
    return slug || 'unknown';
}

// Escape HTML special characters to prevent XSS when interpolating into innerHTML
function escapeHtml(str) {
    if (!str && str !== 0) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

function getUserEntries(data) {
    const users = data?.users;
    if (!users || typeof users !== 'object') {
        return [];
    }
    return Object.entries(users).filter(([username, userData]) => {
        return Boolean(username) && userData && typeof userData === 'object';
    });
}

function getExpectedUsers(data) {
    // "Discovery" model: a user becomes expected only after they've reported at least once.
    // So expected users are the currently known keys in the host's users map.
    return getUserEntries(data).map(([u]) => u).sort((a, b) => a.localeCompare(b));
}

// Issue #63: Return the per-user log filename for single-user hosts,
// or null when there are 0 or 2+ users (multi-user hosts use per-row buttons).
function getHostLogFilename(data) {
    const users = getExpectedUsers(data);
    if (users.length !== 1) {
        return null;
    }
    const slug = sanitizeUserSlug(users[0]);
    return `node-${slug}.log`;
}

function getWorstUserHeartbeatTs(data) {
    const entries = getUserEntries(data);
    if (!entries.length) {
        return data?.heart_beat_ts || 0;
    }
    const heartbeats = entries
        .map(([_, userData]) => Number(userData.heart_beat_ts || 0))
        .filter((ts) => Number.isFinite(ts) && ts > 0);
    if (!heartbeats.length) {
        return 0;
    }
    return Math.min(...heartbeats);
}

function getUserHeartbeatWarningHours(data) {
    // Prefer per-host configured threshold emitted by run.sh, otherwise default to 24h.
    // IMPORTANT: The stale threshold must be significantly larger than the heartbeat threshold (8h)
    // to avoid false positives. If processes run hourly and heartbeats update every 8 hours,
    // marking as stale after exactly 8 hours would cause false positives.
    // Default: 24 hours (3x the 8-hour heartbeat threshold) - fixes issue #15
    const h = Number(data?.user_stale_hours);
    if (Number.isFinite(h) && h > 0) return h;
    return THRESHOLDS.USER_STALE_DEFAULT_HOURS;
}

// Issue #69: Determine per-user status considering both staleness and exceptions.
// Returns "stale" if the user's heartbeat is beyond the warning threshold,
// "errors" if the user has exception_count > 0, or "ok" otherwise.
function getUserStatus(userData, nowTs, warnHours) {
    const ts = Number(userData?.heart_beat_ts || 0);
    const hoursSince = ts > 0 && Number.isFinite(ts) ? (nowTs - ts) / 3600 : Number.POSITIVE_INFINITY;
    const isStale = !ts || !Number.isFinite(ts) || hoursSince > warnHours;
    if (isStale) {
        return 'stale';
    }
    const exceptionCount = parseInt(userData?.exception_count || 0);
    if (exceptionCount > 0) {
        return 'errors';
    }
    return 'ok';
}

// Get list of stale users with their heartbeat information - Issue #22
function getStaleUsers(data, nowTs) {
    const expectedUsers = getExpectedUsers(data);
    if (expectedUsers.length < 2) {
        return []; // Only check multi-user hosts
    }
    const warnHours = getUserHeartbeatWarningHours(data);
    const usersMap = data?.users && typeof data.users === 'object' ? data.users : {};
    const staleUsers = [];
    expectedUsers.forEach((username) => {
        const ts = Number(usersMap?.[username]?.heart_beat_ts || 0);
        const hoursSince = ts > 0 ? (nowTs - ts) / 3600 : Number.POSITIVE_INFINITY;
        const isStale = !ts || !Number.isFinite(ts) || hoursSince > warnHours;
        if (isStale) {
            staleUsers.push({
                username,
                heartbeatTs: ts,
                hoursSince: Math.floor(hoursSince)
            });
        }
    });
    return staleUsers;
}

// Build warning text for stale users - Issue #22
function buildStaleUserWarning(data, nowTs) {
    const staleUsers = getStaleUsers(data, nowTs);
    if (staleUsers.length === 0) {
        return '';
    }
    const userDetails = staleUsers.map(u => {
        if (u.heartbeatTs > 0) {
            return `${u.username} (${formatTimestamp(u.heartbeatTs)})`;
        }
        return `${u.username} (never seen)`;
    }).join(', ');
    return `Stale user${staleUsers.length > 1 ? 's' : ''}: ${userDetails}`;
}

// Get idle worker status by comparing 1m, 5m and 15m load averages - Issue #23
// Returns an object with idle status and details to help detect workers not doing meaningful work
// The key insight is:
// - If all averages (1m, 5m, 15m) are low, the machine is consistently idle
// - If 15m is high but 1m/5m are low, work finished recently (not a concern)
// - If 15m is low but 1m/5m are high, work just started (not a concern)
// - Only flag when the machine appears consistently underutilised
function getIdleWorkerStatus(data) {
    const result = {
        isIdle: false,
        reason: '',
        load1m: null,
        load5m: null,
        load15m: null,
        coreCount: 0
    };

    // Need load_averages and cpu_cores data
    if (!data.load_averages || !data.cpu_cores) {
        return result;
    }

    const coreCount = parseInt(data.cpu_cores);
    if (!Number.isFinite(coreCount) || coreCount <= 0) {
        return result;
    }
    result.coreCount = coreCount;

    // Parse load averages from format like "43.6% (1m), 73.2% (5m), 56.6% (15m)"
    const load1mMatch = data.load_averages.match(/(\d+\.?\d*)%\s*\(1m\)/);
    const load5mMatch = data.load_averages.match(/(\d+\.?\d*)%\s*\(5m\)/);
    const load15mMatch = data.load_averages.match(/(\d+\.?\d*)%\s*\(15m\)/);

    if (!load1mMatch || !load5mMatch || !load15mMatch) {
        return result;
    }

    const load1m = parseFloat(load1mMatch[1]);
    const load5m = parseFloat(load5mMatch[1]);
    const load15m = parseFloat(load15mMatch[1]);

    if (!Number.isFinite(load1m) || !Number.isFinite(load5m) || !Number.isFinite(load15m)) {
        return result;
    }

    result.load1m = load1m;
    result.load5m = load5m;
    result.load15m = load15m;

    // Only check multi-core systems as single-core systems have different usage patterns
    if (coreCount <= THRESHOLDS.IDLE_MIN_CORES) {
        return result;
    }

    // Check for consistently idle machine - all averages are low
    if (load1m < THRESHOLDS.IDLE_LOAD_1M && load5m < THRESHOLDS.IDLE_LOAD_5M && load15m < THRESHOLDS.IDLE_LOAD_15M) {
        result.isIdle = true;
        result.reason = `Worker idle: ${load1m.toFixed(1)}% (1m), ${load5m.toFixed(1)}% (5m), ${load15m.toFixed(1)}% (15m) on ${coreCount} cores`;
        return result;
    }

    // Check for recently stopped work - 15m is higher than current (1m/5m)
    // This is informational, not a warning - work may have just finished
    if (load15m > THRESHOLDS.IDLE_HIGH_LOAD && load1m < THRESHOLDS.IDLE_LOAD_1M && load5m < THRESHOLDS.IDLE_LOAD_5M) {
        // Work appears to have finished recently - not idle, just completed work
        return result;
    }

    // Check for recently started work - 1m/5m are higher than 15m
    // This is informational - work may have just started
    if (load1m > THRESHOLDS.IDLE_HIGH_LOAD && load15m < THRESHOLDS.IDLE_LOAD_15M) {
        // Work appears to have just started - not idle
        return result;
    }

    return result;
}

// Build warning text for idle workers - Issue #23
function buildIdleWorkerWarning(data) {
    const idleStatus = getIdleWorkerStatus(data);
    if (!idleStatus.isIdle) {
        return '';
    }
    return idleStatus.reason;
}

// Count business days (weekdays only) between two unix timestamps (Issue #47)
// Weekends (Saturday=6, Sunday=0) are skipped so they don't count toward staleness
function countBusinessDays(fromTs, toTs) {
    if (toTs <= fromTs) return 0;

    const msPerDay = 86400 * 1000;
    const fromDate = new Date(fromTs * 1000);
    const toDate = new Date(toTs * 1000);

    // Normalise both dates to midnight UTC for whole-day counting
    const fromMidnight = new Date(Date.UTC(fromDate.getUTCFullYear(), fromDate.getUTCMonth(), fromDate.getUTCDate()));
    const toMidnight = new Date(Date.UTC(toDate.getUTCFullYear(), toDate.getUTCMonth(), toDate.getUTCDate()));

    let count = 0;
    let cursor = new Date(fromMidnight.getTime() + msPerDay); // start the day after fromTs
    while (cursor <= toMidnight) {
        const day = cursor.getUTCDay(); // 0=Sun, 6=Sat
        if (day !== 0 && day !== 6) {
            count++;
        }
        cursor = new Date(cursor.getTime() + msPerDay);
    }
    return count;
}

// Issue #77: A repo is "failed" when we have a recorded failure timestamp that
// is at least as new as the most recent successful commit. A failed task is
// more actionable than a stale one, so this state supersedes both healthy and
// error (stale) when both would apply.
function isRepoFailed(repo) {
    if (!repo) return false;
    const failureTs = Number(repo.last_failure_ts || 0);
    if (!Number.isFinite(failureTs) || failureTs <= 0) {
        return false;
    }
    const commitTs = Number(repo.last_commit_ts || 0);
    // Failure wins on ties too — equal timestamps mean the failure is the most
    // recent thing we know, so prefer the actionable state.
    return failureTs >= (Number.isFinite(commitTs) ? commitTs : 0);
}

function getRepoStatus(repo, nowTs) {
    // Calculate status based on last_commit_ts and last_failure_ts
    // Repos with explicit warning_days/error_days use calendar days by default.
    // Repos using defaults skip weekends (business days only) — Issue #47.
    // Repos with business_days_only: true skip weekends even with explicit thresholds — Issue #67.
    // Repos with a recent last_failure_ts return 'failed' — Issue #77.
    // Repos with warning_hours/error_hours use sub-day calendar hours — Issue #105
    // (e.g. Vibe Coders that should check in every hour).
    if (!repo) {
        return 'error';
    }

    // Issue #77: A recent failure is always the most actionable state.
    if (isRepoFailed(repo)) {
        return 'failed';
    }

    if (!repo.last_commit_ts || repo.last_commit_ts <= 0) {
        return 'error'; // No timestamp or invalid repo means error
    }

    const now = nowTs || Math.floor(Date.now() / 1000);

    // Issue #105: hour-grain thresholds win over day-grain thresholds when set.
    // This lets repos with high heartbeat frequency (e.g. Vibe Coders that
    // check in every hour) be flagged within hours of going stale, instead of
    // waiting for the day-grain default to elapse.
    if (repo.warning_hours !== undefined || repo.error_hours !== undefined) {
        const warningHours = repo.warning_hours !== undefined
            ? repo.warning_hours
            : (repo.warning_days !== undefined ? repo.warning_days * 24 : 24);
        const errorHours = repo.error_hours !== undefined
            ? repo.error_hours
            : (repo.error_days !== undefined ? repo.error_days * 24 : 48);
        const hoursSinceCommit = (now - repo.last_commit_ts) / 3600;
        if (hoursSinceCommit > errorHours) {
            return 'error';
        } else if (hoursSinceCommit > warningHours) {
            return 'warning';
        } else {
            return 'healthy';
        }
    }

    const hasExplicitThresholds = repo.warning_days !== undefined || repo.error_days !== undefined;
    const useBusinessDays = repo.business_days_only === true;
    const warningDays = repo.warning_days !== undefined ? repo.warning_days : 1;
    const errorDays = repo.error_days !== undefined ? repo.error_days : 2;

    if (hasExplicitThresholds && !useBusinessDays) {
        // Explicit thresholds without business_days_only: use calendar hours
        const warningHours = warningDays * 24;
        const errorHours = errorDays * 24;
        const hoursSinceCommit = (now - repo.last_commit_ts) / 3600;

        if (hoursSinceCommit > errorHours) {
            return 'error';
        } else if (hoursSinceCommit > warningHours) {
            return 'warning';
        } else {
            return 'healthy';
        }
    } else {
        // Default thresholds or business_days_only: count only business days (skip weekends)
        const businessDays = countBusinessDays(repo.last_commit_ts, now);

        if (businessDays > errorDays) {
            return 'error';
        } else if (businessDays > warningDays) {
            return 'warning';
        } else {
            return 'healthy';
        }
    }
}

// Issue #121: A "Vibe Coder:<host>" row that is warning/error/failed while
// the host itself is fresh is a different (more actionable) signal than the
// host vanishing — the host is alive but the worker process on it has
// silently stopped reporting. Surface that mismatch early so the 4h
// warning threshold becomes useful, instead of waiting for the 8h error
// threshold to trip.
function findVibeCoderRepo(repos, hostname) {
    if (!Array.isArray(repos) || !hostname) return null;
    const target = `Vibe Coder:${hostname}`;
    return repos.find((r) => r && r.name === target) || null;
}

// Worker repo states that indicate the worker has gone silent.
function isWorkerSilentState(status) {
    return status === 'warning' || status === 'error' || status === 'failed';
}

// Return descriptive info when the host's Vibe Coder repo is silent.
// Callers decide whether the host's own heartbeat is fresh enough to
// classify this as "worker silent on alive host" — this helper only
// reports the worker repo state.
function getWorkerSilentInfo(hostname, repos, nowTs) {
    const repo = findVibeCoderRepo(repos, hostname);
    if (!repo) return null;
    const status = getRepoStatus(repo, nowTs);
    if (!isWorkerSilentState(status)) return null;
    return {
        repoName: repo.name,
        repoStatus: status,
        lastCommitTs: Number(repo.last_commit_ts || 0)
    };
}

// Build a short human-readable reason for the warning panel, e.g.
// "Worker silent: Vibe Coder:GRQ-23 last reported 5h ago (warning)".
function buildWorkerSilentWarning(hostname, repos, nowTs) {
    const info = getWorkerSilentInfo(hostname, repos, nowTs);
    if (!info) return '';
    const when = info.lastCommitTs > 0
        ? `last reported ${formatTimestamp(info.lastCommitTs)}`
        : 'has never reported';
    return `Worker silent: ${info.repoName} ${when} (${info.repoStatus})`;
}

// Issue #77: Build a safe URL to view the captured failure log. The stored
// `last_failure_log` path is relative to the docs/ directory (e.g.
// "logs/Quality/20260417-025717.log"), matching the repo layout produced by
// helpers/repos.sh --failed. The "/" separators must be preserved while the
// individual path segments are URI-encoded to handle task slugs that may still
// contain unsafe characters (e.g. spaces in names such as "Vibe Coder-GRQ-23").
function getRepoFailureLogUrl(repo) {
    if (!repo) return '';
    const raw = String(repo.last_failure_log || '').trim();
    if (!raw) return '';
    // Encode each path segment but leave "/" as a separator. Strip any leading
    // "./" or "/" to produce a clean relative URL.
    const trimmed = raw.replace(/^\.\/+/, '').replace(/^\/+/, '');
    const encoded = trimmed
        .split('/')
        .map((segment) => encodeURIComponent(segment))
        .join('/');
    return `./log-viewer.html?file=./${encoded}`;
}

function getRepoStats(reposOverride) {
    // Accepts an optional array of repos (used by tests). Falls back to the
    // module-scope repoHealthData populated by fetchRepoHealth at runtime.
    let repos = reposOverride;
    if (!Array.isArray(repos)) {
        if (typeof repoHealthData !== 'undefined'
            && repoHealthData
            && Array.isArray(repoHealthData.repos)) {
            repos = repoHealthData.repos;
        } else {
            return { total: 0, healthy: 0, warning: 0, error: 0, failed: 0 };
        }
    }
    return repos.reduce((acc, repo) => {
        acc.total += 1;
        const status = getRepoStatus(repo);
        if (status === 'failed') acc.failed += 1;
        else if (status === 'warning') acc.warning += 1;
        else if (status === 'error') acc.error += 1;
        else acc.healthy += 1;
        return acc;
    }, { total: 0, healthy: 0, warning: 0, error: 0, failed: 0 });
}

async function fetchRepoHealth(timestamp = Date.now(), force = false) {
    const now = Date.now();
    if (!force && now - lastRepoRefresh < 5 * 60 * 1000) {
        return;
    }
    try {
        const response = await fetch(`./repos.json?t=${timestamp}`);
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        repoHealthData = await response.json();
        lastRepoRefresh = now;
        renderRepoHealth();
    } catch (error) {
        console.warn('Unable to load repo health data:', error);
        renderRepoHealth('Unable to load repo health data');
    }
}

// Issue #77: Build tooltip text summarising a failure — absolute + relative
// time plus optional exit code and message. Safe for use in a title attribute.
function buildFailureTooltip(repo) {
    if (!repo || !repo.last_failure_ts) return '';
    const ts = Number(repo.last_failure_ts);
    if (!Number.isFinite(ts) || ts <= 0) return '';
    const iso = new Date(ts * 1000).toISOString().replace('T', ' ').replace(/\..+$/, ' UTC');
    const relative = formatTimestamp(ts);
    const parts = [`Failed ${relative} (${iso})`];
    if (repo.last_failure_exit_code !== undefined && repo.last_failure_exit_code !== null && repo.last_failure_exit_code !== '') {
        parts.push(`exit code ${repo.last_failure_exit_code}`);
    }
    if (repo.last_failure_message) {
        parts.push(String(repo.last_failure_message));
    }
    return parts.join(' — ');
}

function renderRepoHealth(errorMessage = null) {
    const section = document.getElementById('repoHealthSection');
    if (!section) {
        return;
    }
    const listElement = document.getElementById('repoHealthList');
    const updatedAtElement = document.getElementById('repoUpdatedAt');
    const healthyCountElement = document.getElementById('repoHealthyCount');
    const warningCountElement = document.getElementById('repoWarningCount');
    const errorCountElement = document.getElementById('repoErrorCount');
    const failedCountElement = document.getElementById('repoFailedCount');
    const repos = repoHealthData?.repos ?? [];

    if (!repos.length && !errorMessage) {
        section.style.display = 'none';
        return;
    }

    section.style.display = 'block';

    const repoStats = getRepoStats();
    healthyCountElement.textContent = `${repoStats.healthy} good`;
    warningCountElement.textContent = `${repoStats.warning} warning`;
    errorCountElement.textContent = `${repoStats.error} error`;
    // Issue #77: Failed counter is displayed only when there is at least one
    // failed task, otherwise it stays hidden to keep the header tidy.
    if (failedCountElement) {
        failedCountElement.textContent = `${repoStats.failed} failed`;
        failedCountElement.style.display = repoStats.failed > 0 ? 'inline-flex' : 'none';
    }

    // Calculate last update from most recent last_commit_ts
    if (repos.length > 0) {
        const mostRecentTs = Math.max(...repos.map(r => r.last_commit_ts || 0));
        if (mostRecentTs > 0) {
            updatedAtElement.textContent = formatTimestamp(mostRecentTs);
        } else {
            updatedAtElement.textContent = 'Awaiting data...';
        }
    } else if (errorMessage) {
        updatedAtElement.textContent = errorMessage;
    } else {
        updatedAtElement.textContent = 'Awaiting data...';
    }

    if (!repos.length) {
        listElement.innerHTML = `<p class="text-muted mb-0">${escapeHtml(errorMessage) || 'No market feed repos configured.'}</p>`;
        return;
    }

    const statusBadge = (status) => {
        if (status === 'failed') return 'badge bg-danger repo-failed-badge';
        if (status === 'error') return 'badge bg-danger';
        if (status === 'warning') return 'badge bg-warning text-dark';
        return 'badge bg-success';
    };

    const repoItemsHtml = repos.map((repo) => {
        // Calculate status from last_commit_ts and last_failure_ts (Issue #77)
        const status = getRepoStatus(repo) || 'error';
        const repoName = escapeHtml(repo.name || 'Unknown');
        const statusLabel = status.charAt(0).toUpperCase() + status.slice(1);

        // Issue #77: For failed repos render a "View log" link with tooltip.
        let failureHtml = '';
        if (status === 'failed') {
            const logUrl = getRepoFailureLogUrl(repo);
            const tooltip = buildFailureTooltip(repo);
            const failureTimeText = repo.last_failure_ts
                ? `Failed ${formatTimestamp(repo.last_failure_ts)}`
                : 'Failed';
            const linkHtml = logUrl
                ? `<a href="${escapeHtml(logUrl)}" target="_blank" rel="noopener" class="repo-view-log btn btn-sm btn-outline-danger"
                      ${tooltip ? `title="${escapeHtml(tooltip)}" data-bs-toggle="tooltip" data-bs-placement="left"` : ''}>
                      <i class="bi bi-file-earmark-text"></i> View log
                   </a>`
                : '';
            failureHtml = `
                <div class="repo-failure-info">
                    <div class="repo-time text-danger">${escapeHtml(failureTimeText)}</div>
                    ${linkHtml}
                </div>
            `;
        }

        return `
        <div class="repo-health-item repo-${status}">
            <div class="repo-meta">
                <div class="repo-name">${repoName}</div>
                <div class="repo-slug">${escapeHtml(repo.repo || '')}</div>
            </div>
            <div class="text-end">
                <span class="${statusBadge(status)} repo-status-badge">${statusLabel}</span>
                <div class="repo-time">${repo.last_commit_ts > 0 ? `Last commit ${formatTimestamp(repo.last_commit_ts)}` : 'Commit time unavailable'}</div>
                ${repo.error_message ? `<div class="repo-error text-danger"><small>${escapeHtml(repo.error_message)}</small></div>` : ''}
                ${failureHtml}
            </div>
        </div>
    `;
    }).join('');

    const alertHtml = errorMessage
        ? `<div class="alert alert-warning mb-3">${escapeHtml(errorMessage)}</div>`
        : '';

    listElement.innerHTML = `${alertHtml}${repoItemsHtml}`;

    // Issue #77: Initialise Bootstrap tooltips for the failure links after render.
    if (typeof initializeTooltips === 'function') {
        try { initializeTooltips(); } catch (_e) { /* tooltips are best-effort */ }
    }
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
      <p class="mb-3">${escapeHtml(message)}</p>
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

// Issue #49: Hysteresis for disk usage warning to prevent oscillation.
// Returns true if disk should be in warning state.
// - Triggers warning when diskPercent >= DISK_WARNING_PERCENT
// - Clears warning only when diskPercent <= DISK_WARNING_CLEAR_PERCENT
// - In the hysteresis band, maintains the previous state
function isDiskWarning(diskPercent, wasPreviouslyWarning) {
    if (diskPercent >= THRESHOLDS.DISK_WARNING_PERCENT) {
        return true;
    }
    if (diskPercent <= THRESHOLDS.DISK_WARNING_CLEAR_PERCENT) {
        return false;
    }
    // In the hysteresis band — maintain previous state
    return !!wasPreviouslyWarning;
}

// Issue #84: Build a descriptive disk warning message that distinguishes
// above-threshold from hysteresis-band cases.
function buildDiskWarningMessage(diskPercent) {
    if (diskPercent >= THRESHOLDS.DISK_WARNING_PERCENT) {
        return `High disk usage: ${diskPercent}% (>= ${THRESHOLDS.DISK_WARNING_PERCENT}%)`;
    }
    // In hysteresis band (below warning threshold but above clear threshold)
    return `High disk usage: ${diskPercent}% (in hysteresis band, will clear at or below ${THRESHOLDS.DISK_WARNING_CLEAR_PERCENT}%)`;
}

function getHealthStatus(_hostname, data, options) {
    // Check if this is a dead machine
    if (data.death_date) {
        return 'dead';
    }

    // Host-level heartbeat: when the host itself was last seen.
    // This is used for critical/MIA determination (Issue #26).
    const hostHeartbeatTs = data?.heart_beat_ts || 0;

    // Multi-user hosts: consider the *worst* (oldest) user's heartbeat so one user's updates can't mask another user's stuck state.
    // This is used for per-user stale warning detection only — not for critical status.
    const expectedUsers = getExpectedUsers(data);
    const worstUserHeartbeatTs = getWorstUserHeartbeatTs(data);

    // For critical/MIA determination, use the host-level heartbeat.
    // A stale user should trigger a warning, not mark the entire host as critical.
    // Fall back to worst user heartbeat only if there is no host-level heartbeat (Issue #26).
    const effectiveHeartbeatTs = hostHeartbeatTs || worstUserHeartbeatTs;

    // Check if this is a mobile host without heartbeat
    if (data.mobile && !effectiveHeartbeatTs) {
        // For mobile hosts without heartbeat, mark as historical
        return 'historical';
    }

    // For active hosts without heartbeat, mark as critical (unless mobile)
    if (!effectiveHeartbeatTs) {
        return 'critical';
    }

    const now = Math.floor(Date.now() / 1000);
    const hoursSinceHeartbeat = (now - effectiveHeartbeatTs) / 3600;

    // Handle timezone issues - if heartbeat is in the future, assume it's recent
    if (effectiveHeartbeatTs > now) {
        return 'healthy';
    }

    // Check for MIA state (mobile hosts not seen beyond threshold)
    if (hoursSinceHeartbeat > THRESHOLDS.HEARTBEAT_CRITICAL_HOURS && data.mobile) {
        return 'mia';
    }

    // Check for critical state (no heartbeat beyond threshold)
    // Mobile hosts are now marked as MIA instead of critical
    if (hoursSinceHeartbeat > THRESHOLDS.HEARTBEAT_CRITICAL_HOURS && !data.mobile) {
        return 'critical';
    }

    // Check for warning states
    if (hoursSinceHeartbeat <= THRESHOLDS.HEARTBEAT_CRITICAL_HOURS) {
        // Per-user stale detection: if any expected user is missing/stale beyond the user heartbeat threshold, flag WARNING.
        // This ensures "elephant stuck" makes the host warning even if the host itself updated recently.
        if (expectedUsers.length >= 2) {
            const warnHours = getUserHeartbeatWarningHours(data);
            const usersMap = data?.users && typeof data.users === 'object' ? data.users : {};
            const anyUserStale = expectedUsers.some((u) => {
                const ts = Number(usersMap?.[u]?.heart_beat_ts || 0);
                if (!ts || !Number.isFinite(ts)) return true; // missing counts as stale
                return (now - ts) / 3600 > warnHours;
            });
            if (anyUserStale) {
                return 'warning';
            }
            // Issue #69: Per-user exception detection — if any user has errors, flag host as warning.
            const anyUserExceptions = expectedUsers.some((u) => {
                return parseInt(usersMap?.[u]?.exception_count || 0) > 0;
            });
            if (anyUserExceptions) {
                return 'warning';
            }
        }

        // Disk usage warning with hysteresis (Issue #49) - applies to all hosts including mobile
        if (data.used_disk_percent) {
            const diskPct = parseFloat(data.used_disk_percent);
            const wasDiskWarning = !!(options && options.diskWarningActive);
            if (isDiskWarning(diskPct, wasDiskWarning)) {
                return 'warning';
            }
        }
        
        // Config warning (missing PRIMARY_READ_URL or TRAINING_WRITE_URL)
        if (data.config_warning && data.config_warning.trim().length > 0) {
            return 'warning';
        }
        
        // Idle worker detection - Issue #23
        // Uses 1m, 5m, and 15m load averages to detect workers not doing meaningful work
        // A worker is flagged as idle only when ALL averages are consistently low
        // This avoids false positives from momentary lulls or workers that just finished/started work
        const idleStatus = getIdleWorkerStatus(data);
        if (idleStatus.isIdle) {
            return 'warning';
        }
        
        // OS version warning (basic check)
        if (data.os_info && data.os_version) {
            if (data.os_info.includes('macOS') && data.os_version < THRESHOLDS.MACOS_MIN_VERSION) {
                return 'warning';
            }
            if (data.os_info.includes('Ubuntu') && data.os_version < THRESHOLDS.UBUNTU_MIN_VERSION) {
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
    const healthStatus = getCachedHealthStatus(hostname);
    const statusClass = healthStatus;
    const safeHostname = escapeHtml(hostname);
    // Issue #63: Use per-user log filename for single-user hosts
    const hostLogFile = getHostLogFilename(data);
    const logUrl = hostLogFile
        ? `./log-viewer.html?file=./${safeHostname}/${hostLogFile}`
        : `./log-viewer.html?file=./${safeHostname}/node.log`;
    const emoji = escapeHtml(data.emoji || '');
    const location = escapeHtml(data.location || '');

    const userEntries = getUserEntries(data);
    const expectedUsers = getExpectedUsers(data);
    const showUserTable = expectedUsers.length >= 2;
    const displayHeartbeatTs = showUserTable ? getWorstUserHeartbeatTs(data) : data.heart_beat_ts;
    const userTableHtml = showUserTable ? (() => {
        const now = Math.floor(Date.now() / 1000);
        const usersMap = data?.users && typeof data.users === 'object' ? data.users : {};
        const warnHours = getUserHeartbeatWarningHours(data);
        const rows = expectedUsers
            .map((username) => {
                const userData = usersMap?.[username] || {};
                const ts = Number(userData.heart_beat_ts || 0);
                const tsText = ts > 0 ? formatTimestamp(ts) : 'Unknown';
                // Issue #69: Use getUserStatus to check staleness AND exceptions
                const userSt = getUserStatus(userData, now, warnHours);
                const statusBadge = userSt === 'stale'
                    ? '<span class="badge bg-danger">stale</span>'
                    : userSt === 'errors'
                    ? '<span class="badge bg-warning text-dark">errors</span>'
                    : '<span class="badge bg-success">ok</span>';
                const slug = sanitizeUserSlug(username);
                const userLogUrl = `./log-viewer.html?file=./${safeHostname}/node-${slug}.log`;
                return `
                    <tr>
                        <td class="text-nowrap">${escapeHtml(username)}</td>
                        <td class="text-nowrap">${tsText}</td>
                        <td class="text-end text-nowrap">${statusBadge}</td>
                        <td class="text-end text-nowrap"><a href="${userLogUrl}" class="btn btn-sm btn-outline-secondary">Log</a></td>
                    </tr>
                `;
            })
            .join('');
        return `
            <div class="row mt-2">
                <div class="col-12">
                    <small class="text-muted">Users (stale after ${warnHours}h)</small>
                    <div class="table-responsive">
                        <table class="table table-sm table-striped mb-0">
                            <thead>
                                <tr>
                                    <th>User</th>
                                    <th>Last heartbeat</th>
                                    <th class="text-end">Status</th>
                                    <th class="text-end">Log</th>
                                </tr>
                            </thead>
                            <tbody>${rows}</tbody>
                        </table>
                    </div>
                </div>
            </div>
        `;
    })() : '';
    
    if (healthStatus === 'dead') {
        return `
            <div class="col-lg-6 col-xl-4">
                <div class="host-card dead" data-status="dead">
                    <div class="d-flex justify-content-between align-items-center mb-3">
                        <h5 class="mb-0">${emoji} ${safeHostname}</h5>
                        <span class="health-status dead">Dead</span>
                    </div>
                    ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                    <div class="row">
                        <div class="col-12">
                            <small class="text-muted">Death Date</small>
                            <div class="fw-bold">${escapeHtml(data.death_date)}</div>
                        </div>
                    </div>
                    ${data.os_info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">OS</small><div class="fw-bold">${escapeHtml(data.os_info)}</div></div></div>` : ''}
                    ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${escapeHtml(data.info)}</div></div></div>` : ''}
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
                        <h5 class="mb-0">${emoji} ${safeHostname}</h5>
                        <span class="health-status historical">Historical</span>
                    </div>
                    ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                    <div class="row">
                        <div class="col-6">
                            <small class="text-muted">OS</small>
                            <div class="fw-bold">${escapeHtml(data.os_info)}</div>
                        </div>
                        <div class="col-6">
                            <small class="text-muted">Last Seen</small>
                            <div class="fw-bold">${escapeHtml(data.last_seen || 'Unknown')}</div>
                        </div>
                    </div>
                    ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${escapeHtml(data.info)}</div></div></div>` : ''}
                    ${data.sample_rate ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Sample Rate</small><div class="fw-bold">${escapeHtml(data.sample_rate)}</div></div></div>` : ''}
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
                        <h5 class="mb-0">${miaEmoji} ${safeHostname}</h5>
                        <span class="health-status mia">Off the Grid</span>
                    </div>
                    ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                    <div class="row">
                        <div class="col-6">
                            <small class="text-muted">OS</small>
                            <div class="fw-bold">${escapeHtml(data.os_info)} ${escapeHtml(data.os_version)}</div>
                        </div>
                        <div class="col-6">
                            <small class="text-muted">Last Seen</small>
                            <div class="fw-bold">${data.heart_beat_ts ? formatTimestamp(data.heart_beat_ts) : 'Unknown'}</div>
                        </div>
                    </div>
                    ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${escapeHtml(data.info)}</div></div></div>` : ''}
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
    
    // Issue #121: Surface a "Worker silent" badge when the host's heartbeat
    // is fresh but its Vibe Coder worker has gone quiet. This is the strong
    // "alive host, dead worker" signal — distinct from a host that is offline.
    const workerSilent = getCachedWorkerSilentInfo(hostname);
    const workerSilentBadge = workerSilent
        ? `<span class="badge bg-warning text-dark ms-2 worker-silent-badge" title="${escapeHtml(workerSilent.repoName)} ${escapeHtml(workerSilent.repoStatus)}" data-bs-toggle="tooltip" data-bs-placement="top"><i class="bi bi-robot"></i> Worker silent</span>`
        : '';
    return `
        <div class="col-lg-6 col-xl-4">
            <div class="host-card ${statusClass}${mobileClass}${outdatedMacClass}" data-status="${healthStatus}" data-hostname="${escapeHtml(hostname)}">
                <div class="d-flex justify-content-between align-items-center mb-3">
                    <h5 class="mb-0 d-flex align-items-center">
                        ${emoji} ${safeHostname}
                        ${data.machine_type && data.machine_type !== 'unknown' && data.machine_type !== '' ? `<span class="badge bg-secondary ms-2" style="font-size: 0.7rem;">${escapeHtml(data.machine_type)}</span>` : ''}
                        ${workerSilentBadge}
                    </h5>
                    <span class="health-status ${statusClass}">${healthStatus}</span>
                </div>
                ${location ? `<div class="location mb-2"><small class="text-muted">📍 ${location}</small></div>` : ''}
                <div class="row">
                    <div class="col-6">
                        <small class="text-muted">OS</small>
                        <div class="fw-bold">
                            ${escapeHtml(data.os_info)} ${escapeHtml(data.os_version)}
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
                        <div class="fw-bold">${escapeHtml(diskDisplay)}</div>
                    </div>
                    <div class="col-6">
                        <small class="text-muted">Memory</small>
                        <div class="fw-bold">${escapeHtml(memDisplay)}</div>
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-6">
                        <small class="text-muted">CPU Load</small>
                        <div class="fw-bold">${escapeHtml(cpuDisplay)}</div>
                        ${data.cpu_breakdown ? `<small class="text-muted">${escapeHtml(data.cpu_breakdown)}</small>` : ''}
                        ${data.load_averages ? `<small class="text-muted">Recent: ${escapeHtml(data.load_averages)}</small>` : ''}
                    </div>
                    <div class="col-6">
                        <small class="text-muted">Network</small>
                        <div class="fw-bold">${escapeHtml(data.network_status)}</div>
                        ${data.ip_addresses ? `<small class="text-muted">${escapeHtml(data.ip_addresses)}</small>` : ''}
                    </div>
                </div>
                <div class="row mt-2">
                    <div class="col-6">
                        <small class="text-muted">Timezone</small>
                        <div class="fw-bold">${escapeHtml(data.timezone)}</div>
                    </div>
                </div>
                ${userTableHtml}
                ${data.config_warning ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Config</small><div class="fw-bold text-warning">${escapeHtml(data.config_warning)}</div></div></div>` : ''}
                ${data.info ? `<div class="row mt-2"><div class="col-12"><small class="text-muted">Info</small><div class="fw-bold">${escapeHtml(data.info)}</div></div></div>` : ''}
                <div class="last-seen">Last seen: ${displayHeartbeatTs ? formatTimestamp(displayHeartbeatTs) : 'Unknown'}</div>
                <div class="d-flex justify-content-center align-items-center mt-2 position-relative">
                    <div class="text-center">
                        ${data.version ? `<small class="text-muted" style="font-size: 0.6rem; opacity: 0.6;" title="Health script version">v${escapeHtml(data.version)}</small>` : ''}
                    </div>
                    ${!showUserTable ? `
                    <div class="position-absolute" style="right: 0;">
                        <a href="${logUrl}" class="btn btn-sm ${data.exception_count && parseInt(data.exception_count) > 0 ? 'btn-danger' : 'btn-outline-primary'}"
                           ${data.exception_count && parseInt(data.exception_count) > 0 ? `title="${escapeHtml(data.exception_summary)}" data-bs-toggle="tooltip" data-bs-placement="top"` : ''}>
                            <i class="bi ${data.exception_count && parseInt(data.exception_count) > 0 ? 'bi-exclamation-triangle' : 'bi-file-text'}"></i>
                            ${data.exception_count && parseInt(data.exception_count) > 0 ? 'View Log ⚠️' : 'View Log'}
                        </a>
                    </div>
                    ` : ''}
                </div>
            </div>
        </div>
    `;
    }

// Issue #49: Wrapper that applies disk hysteresis state tracking.
// Call once per host per refresh cycle to update state, then use cached result.
// Issue #121: Also tracks worker-silent state so a fresh host whose Vibe
// Coder worker has gone quiet shows up as a warning instead of staying
// silently healthy until the 8h error threshold trips.
const _healthStatusCache = {};
const _workerSilentCache = {};
function refreshHealthStatuses(hosts) {
    // Clear caches for new refresh cycle
    Object.keys(_healthStatusCache).forEach(k => delete _healthStatusCache[k]);
    Object.keys(_workerSilentCache).forEach(k => delete _workerSilentCache[k]);
    const repos = Array.isArray(repoHealthData?.repos) ? repoHealthData.repos : [];
    const nowTs = Math.floor(Date.now() / 1000);
    for (const [hostname, data] of hosts) {
        const opts = { diskWarningActive: !!diskWarningState[hostname] };
        let status = getHealthStatus(hostname, data, opts);
        // Issue #121: A fresh host (healthy) whose worker is silent should be
        // surfaced as a warning so the diagnostic signal is not delayed by
        // the 8h error threshold. Only elevate from healthy — if the host is
        // already in critical/mia/dead/warning, the existing classification
        // is preserved.
        const workerInfo = getWorkerSilentInfo(hostname, repos, nowTs);
        if (workerInfo) {
            _workerSilentCache[hostname] = workerInfo;
            if (status === 'healthy') {
                status = 'warning';
            }
        }
        _healthStatusCache[hostname] = status;
        // Update disk warning state for next cycle
        if (data.used_disk_percent) {
            diskWarningState[hostname] = isDiskWarning(
                parseFloat(data.used_disk_percent),
                opts.diskWarningActive
            );
        }
    }
}

function getCachedWorkerSilentInfo(hostname) {
    return _workerSilentCache[hostname] || null;
}

function getCachedHealthStatus(hostname) {
    return _healthStatusCache[hostname] || 'healthy';
}

function updateStats(hosts) {
    const stats = {
        total: hosts.length,
        healthy: hosts.filter(([hostname]) => getCachedHealthStatus(hostname) === 'healthy').length,
        warning: hosts.filter(([hostname]) => getCachedHealthStatus(hostname) === 'warning').length,
        critical: hosts.filter(([hostname]) => getCachedHealthStatus(hostname) === 'critical').length,
        mia: hosts.filter(([hostname]) => getCachedHealthStatus(hostname) === 'mia').length
    };
    const repoStats = getRepoStats();
    const hasRepoError = repoStats.error > 0;
    const hasRepoWarning = repoStats.warning > 0;
    // Issue #77: a repo "failed" state is unhealthy — we have concrete evidence
    // of a task failure, which is just as bad as stale data from the
    // uptime-monitor's point of view.
    const hasRepoFailed = repoStats.failed > 0;

    document.getElementById('totalHosts').textContent = stats.total;
    document.getElementById('healthyHosts').textContent = stats.healthy;
    document.getElementById('warningHosts').textContent = stats.warning;
    document.getElementById('criticalHosts').textContent = stats.critical;

    // Update page title and header based on overall health
    // Only count critical devices as unhealthy - MIA devices are just missing, not unhealthy.
    // Issue #77: any failed repo is also considered unhealthy.
    const isHealthy = stats.critical === 0 && !hasRepoError && !hasRepoFailed;
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
        if (stats.critical > 0 && (hasRepoError || hasRepoFailed)) {
            headerSubtitle.textContent = "Hosts and market feed tasks need attention";
        } else if (stats.critical > 0) {
            headerSubtitle.textContent = "Some hosts not responding";
        } else if (hasRepoFailed && hasRepoError) {
            headerSubtitle.textContent = "Market feed tasks have failed runs and are stale";
        } else if (hasRepoFailed) {
            headerSubtitle.textContent = `Market feed task${repoStats.failed > 1 ? 's have' : ' has'} failed — check the latest log`;
        } else if (hasRepoError) {
            headerSubtitle.textContent = "Market feed tasks are stale";
        } else if (stats.mia > 0) {
            headerSubtitle.textContent = `All hosts responding normally (${stats.mia} mobile device${stats.mia > 1 ? 's' : ''} off the grid)`;
        } else if (hasRepoWarning) {
            headerSubtitle.textContent = "Market feed tasks require attention";
        } else {
            headerSubtitle.textContent = "All hosts and feed tasks responding normally";
        }
    }

    // Show critical hosts section if there are any
    const criticalSection = document.getElementById('criticalSection');
    const criticalHostsList = document.getElementById('criticalHostsList');
    if (stats.critical > 0) {
        const criticalHosts = hosts.filter(([hostname]) => getCachedHealthStatus(hostname) === 'critical');
        const criticalHtml = criticalHosts.map(([hostname, data]) => {
            if (data.heart_beat_ts) {
                const hoursSince = Math.floor((Math.floor(Date.now() / 1000) - data.heart_beat_ts) / 3600);
                return `<div class="critical-host-item">
                    <strong>${escapeHtml(hostname)}</strong> - Last seen: ${formatTimestamp(data.heart_beat_ts)} (${hoursSince} hours ago)
                </div>`;
            } else {
                return `<div class="critical-host-item">
                    <strong>${escapeHtml(hostname)}</strong> - No heartbeat data available
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
        const miaHosts = hosts.filter(([hostname]) => getCachedHealthStatus(hostname) === 'mia');
        const miaHtml = miaHosts.map(([hostname, data]) => {
            if (data.heart_beat_ts) {
                const hoursSince = Math.floor((Math.floor(Date.now() / 1000) - data.heart_beat_ts) / 3600);
                return `<div class="mia-host-item">
                    <strong>${escapeHtml(hostname)}</strong> - Last seen: ${formatTimestamp(data.heart_beat_ts)} (${hoursSince} hours ago)
                </div>`;
            } else {
                return `<div class="mia-host-item">
                    <strong>${escapeHtml(hostname)}</strong> - No heartbeat data available
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
        const warningHosts = hosts.filter(([hostname]) => getCachedHealthStatus(hostname) === 'warning');
        const warningHtml = warningHosts.map(([hostname, data]) => {
            let warningReason = '';
            if (data.used_disk_percent && diskWarningState[hostname]) {
                warningReason += buildDiskWarningMessage(parseFloat(data.used_disk_percent));
            }
            if (data.config_warning) {
                if (warningReason) warningReason += ', ';
                warningReason += data.config_warning;
            }
            // Issue #23: Idle worker detection using 1m, 5m, 15m load averages
            const idleWorkerWarning = buildIdleWorkerWarning(data);
            if (idleWorkerWarning) {
                if (warningReason) warningReason += ', ';
                warningReason += idleWorkerWarning;
            }
            if (data.os_info && data.os_version) {
                if ((data.os_info.includes('macOS') && data.os_version < THRESHOLDS.MACOS_MIN_VERSION) ||
                    (data.os_info.includes('Ubuntu') && data.os_version < THRESHOLDS.UBUNTU_MIN_VERSION)) {
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
            // Issue #22: Highlight which user has the warning (stale users)
            const now = Math.floor(Date.now() / 1000);
            const staleUserWarning = buildStaleUserWarning(data, now);
            if (staleUserWarning) {
                if (warningReason) warningReason += ', ';
                warningReason += staleUserWarning;
            }
            // Issue #121: Worker silent on an otherwise-fresh host
            const repos = Array.isArray(repoHealthData?.repos) ? repoHealthData.repos : [];
            const workerSilentReason = buildWorkerSilentWarning(hostname, repos, now);
            if (workerSilentReason) {
                if (warningReason) warningReason += ', ';
                warningReason += workerSilentReason;
            }
            return `<div class="warning-host-item">
                <strong>${escapeHtml(hostname)}</strong> - ${escapeHtml(warningReason)}
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
        const status = getCachedHealthStatus(hostname);
        return filter === 'all' || status === filter;
    });
    // Sort: critical first, then warning, then healthy, then historical, then dead, then by last seen (most recent first)
    filteredHosts.sort(([hostnameA, dataA], [hostnameB, dataB]) => {
        const statusA = getCachedHealthStatus(hostnameA);
        const statusB = getCachedHealthStatus(hostnameB);
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
    const existingHostCard = document.querySelector(`[data-hostname="${hostname}"]`);
    if (!existingHostCard) return;

    const wrapper = existingHostCard.closest('.col-lg-6') || existingHostCard.parentElement;
    if (!wrapper) return;

    const temp = document.createElement('div');
    temp.innerHTML = createHostCard(hostname, data).trim();
    const newWrapper = temp.firstElementChild;
    if (!newWrapper) return;

    // Add a subtle highlight effect to the replaced card
    const newHostCard = newWrapper.querySelector('.host-card');
    if (newHostCard) {
        newHostCard.style.transition = 'background-color 0.3s ease';
        newHostCard.style.backgroundColor = 'rgba(40, 167, 69, 0.1)';
        setTimeout(() => {
            newHostCard.style.backgroundColor = '';
        }, 1000);
    }

    wrapper.replaceWith(newWrapper);
    initializeTooltips();
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
        await fetchRepoHealth(timestamp, true);
        
        // Convert to array of [hostname, data] pairs
        allHosts = Object.entries(data);
        
        // Store current data for future comparisons
        previousHosts.clear();
        allHosts.forEach(([hostname, hostData]) => {
            previousHosts.set(hostname, JSON.stringify(hostData));
        });
        
        // Reset the full refresh timer
        lastFullRefresh = Date.now();

        // Issue #49: Refresh health statuses with disk hysteresis
        refreshHealthStatuses(allHosts);
        updateStats(allHosts);
        filterHosts(currentFilter);
        initializeTooltips();
    } catch (error) {
        console.error('Error loading data:', error);
        // Issue #65: Provide specific guidance for different failure modes
        let advice = 'Make sure the index.json file exists and is accessible.';
        if (error instanceof SyntaxError) {
            advice = 'The index.json file appears to be corrupted. A health check from any host will automatically recover it.';
        } else if (error.message && error.message.includes('404')) {
            advice = 'The index.json file is missing. A health check from any host will recreate it.';
        }
        content.innerHTML = `
            <div class="error">
                <h3>Error Loading Data</h3>
                <p>Failed to load health data: ${escapeHtml(error.message)}</p>
                <p>${escapeHtml(advice)}</p>
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
        await fetchRepoHealth(timestamp);
        
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
            
            // Issue #49: Refresh health statuses with disk hysteresis
            refreshHealthStatuses(allHosts);
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