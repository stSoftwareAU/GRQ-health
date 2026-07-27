// The docs/dashboard.js header templates as they stood before Issue #174: the
// hostname text run sits directly in the <h5>, with the machine-type badge as
// a sibling, and nothing carries the full hostname for a truncated card.
function renderPreFixCards() {
    const safeHostname = escapeHtml(hostname);

    const mia = `
        <div class="host-card mia">
            <div class="d-flex justify-content-between align-items-center mb-3">
                <h5 class="mb-0">🏖️ ${safeHostname}</h5>
                <span class="health-status mia">Off the Grid</span>
            </div>
        </div>
    `;

    const active = `
        <div class="host-card healthy">
            <div class="d-flex justify-content-between align-items-center mb-3">
                <h5 class="mb-0 d-flex align-items-center">
                    ${emoji} ${safeHostname}
                    <span class="badge bg-secondary ms-2">${escapeHtml(data.machine_type)}</span>
                </h5>
                <span class="health-status healthy">healthy</span>
            </div>
        </div>
    `;

    return mia + active;
}
