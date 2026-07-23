# Add light/dark/auto theme toggle with remembered choice (Issue #161)

## Summary

Added a light/dark/auto colour-theme selector to all three GRQ-health dashboard
pages (`docs/index.html`, `docs/simple.html`, `docs/log-viewer.html`). The
chosen mode is persisted in the browser's `localStorage` (`grq-theme`) and
restored on every visit. **Auto** is the default for first-time visitors: it
follows the OS `prefers-color-scheme` and reacts live when the OS setting
changes. The original purple-gradient design is the **light** theme; a new,
WCAG-AA-readable navy **dark** palette was added, and the offline (feed-lost)
brown styling is now theme-aware — a deeper brown in dark mode so the offline
state stays clearly distinguishable in both themes. Vanilla JS + CSS only, no
new dependencies, matching GRQ-actual-validation's conventions. Closes #161.

Key implementation choices:

- **`docs/theme.js`** — shared controller. Pure, unit-tested helpers
  (`resolveTheme`, `sanitiseThemeMode`) plus DOM wiring that builds the
  selector, persists the choice, and live-updates when the OS theme changes
  while in auto mode. DOM code is guarded behind `typeof document === 'undefined'`
  so the pure helpers can run under the Deno test harness.
- **`docs/theme.css`** — styling for the selector control only, so it can sit on
  any page background without pulling dashboard rules into the minimal pages.
- **`docs/styles.css`** — hardcoded colours refactored to CSS variables; a
  `[data-theme="dark"]` palette drives the dashboard surfaces (cards, tables,
  host cards, text) and the theme-aware offline browns.
- Each page's `<head>` has a tiny inline `<script data-theme-init>` that applies
  the remembered theme **before first paint** to avoid a flash of the wrong
  theme.
- Version bumped `1.1.18 → 1.1.19` (via `update_version.sh`) so the service
  worker cache invalidates and clients pick up the new assets; `theme.js` and
  `theme.css` were added to the SW precache list.

### Theme resolution flow

```mermaid
flowchart LR
    A[Page load] --> B{localStorage<br/>grq-theme?}
    B -- stored --> C[Use stored mode]
    B -- none --> D[Default: auto]
    C --> E{Mode?}
    D --> E
    E -- light --> F[data-theme=light]
    E -- dark --> G[data-theme=dark]
    E -- auto --> H{OS prefers dark?}
    H -- yes --> G
    H -- no --> F
    I[Click Light/Dark/Auto] --> J[Save to localStorage] --> E
    K[OS theme changes] -->|only when mode=auto| H
```

## Evidence

Captured with the Playwright Chromium headless-shell against a local server of
`docs/`.

Dashboard — light (original design preserved) and dark:

![Dashboard light theme](docs/evidence/issue-161-dashboard-light.png)
![Dashboard dark theme](docs/evidence/issue-161-dashboard-dark.png)

Simple status page — light and dark:

![Simple page light theme](docs/evidence/issue-161-simple-light.png)
![Simple page dark theme](docs/evidence/issue-161-simple-dark.png)

Log viewer — dark (page chrome themed; the log panel stays dark in both themes
because a terminal log reads best on a dark surface):

![Log viewer dark theme](docs/evidence/issue-161-logviewer-dark.png)

## Test Plan

- **Added `tests/test-theme-toggle.sh`** (TDD — written before the wiring):
  - Pure `sanitiseThemeMode` preserves valid modes and defaults unknown/null to
    `auto`.
  - Pure `resolveTheme` — explicit `light`/`dark` ignore the OS preference;
    `auto` (and any invalid mode) follows the OS `prefers-color-scheme`.
  - Wiring — each of the three pages loads `theme.js` and exposes a
    `#theme-toggle` placeholder.
- **Existing tests** — all still pass. Note: adding an inline `<head>` shim
  meant the XSS extraction helpers in `test-xss-simple-html.sh` /
  `test-xss-log-viewer.sh` (which `sed`-slice the first `<script>…</script>`)
  would otherwise have grabbed the shim; the shim tag is written as
  `<script data-theme-init>` so it no longer matches the bare `<script>` those
  helpers key on. No test logic was modified.
- `./quality.sh` — 59/60 pass. The single failure, `test-gitleaks-workflow`, is
  **pre-existing and unrelated** to this change: it inspects
  `.github/workflows/gitleaks.yml`, which this PR does not touch.

## Security self-check

- No secrets or hidden files staged; only `docs/*` assets, `run.sh`, README, and
  a new test.
- Theme choice is read/written to `localStorage` only, validated through
  `sanitiseThemeMode` (allowlist of `light`/`dark`/`auto`) before use — an
  unexpected stored value falls back to `auto`. No user input reaches the DOM as
  HTML; the selector buttons are built from a fixed internal list.
