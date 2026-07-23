// GRQ Health Dashboard — light/dark/auto theme controller (Issue #161)
//
// Shared across index.html, simple.html and log-viewer.html. Persists the
// chosen mode in localStorage and restores it on every visit. "auto" follows
// the OS `prefers-color-scheme` setting and reacts live when it changes.
//
// The pure helpers (sanitiseThemeMode, resolveTheme) are exposed on
// globalThis.GRQTheme so they can be unit-tested under Deno where there is no
// DOM. All DOM-dependent code is skipped when `document` is undefined.
(function () {
  'use strict';

  const STORAGE_KEY = 'grq-theme';
  const MODES = ['light', 'dark', 'auto'];
  const MODE_META = {
    light: { icon: '☀️', label: 'Light' },   // ☀️
    dark: { icon: '\u{1F319}', label: 'Dark' },          // 🌙
    auto: { icon: '\u{1F5A5}️', label: 'Auto' },  // 🖥️
  };

  // Pure: normalise any stored/user value to a valid mode. Unknown or missing
  // values fall back to "auto" (the default for first-time visitors).
  function sanitiseThemeMode(mode) {
    return MODES.indexOf(mode) !== -1 ? mode : 'auto';
  }

  // Pure: resolve a mode plus the OS dark-mode preference into the effective
  // palette ("light" or "dark"). "auto" defers to the OS preference.
  function resolveTheme(mode, systemPrefersDark) {
    const safe = sanitiseThemeMode(mode);
    if (safe === 'auto') {
      return systemPrefersDark ? 'dark' : 'light';
    }
    return safe;
  }

  const api = { sanitiseThemeMode, resolveTheme, MODES, STORAGE_KEY };
  if (typeof globalThis !== 'undefined') {
    globalThis.GRQTheme = api;
  }

  // Nothing below runs without a DOM (e.g. under the Deno test harness).
  if (typeof document === 'undefined') {
    return;
  }

  const media = window.matchMedia
    ? window.matchMedia('(prefers-color-scheme: dark)')
    : null;

  function readStoredMode() {
    try {
      return sanitiseThemeMode(localStorage.getItem(STORAGE_KEY));
    } catch (e) {
      // Private-mode / disabled storage — fail safe to the default.
      return 'auto';
    }
  }

  function persistMode(mode) {
    try {
      localStorage.setItem(STORAGE_KEY, mode);
    } catch (e) {
      // Storage unavailable — the choice simply won't persist. Do not throw.
    }
  }

  // Keep the mobile browser chrome colour in step with the active palette.
  function updateThemeColorMeta(effective) {
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) {
      meta.setAttribute('content', effective === 'dark' ? '#16213e' : '#667eea');
    }
  }

  function applyMode(mode) {
    const systemPrefersDark = media ? media.matches : false;
    const effective = resolveTheme(mode, systemPrefersDark);
    const root = document.documentElement;
    root.setAttribute('data-theme', effective);
    root.setAttribute('data-theme-mode', mode);
    updateThemeColorMeta(effective);
    refreshButtons(mode);
  }

  function setMode(mode) {
    const safe = sanitiseThemeMode(mode);
    persistMode(safe);
    applyMode(safe);
  }

  let buttons = [];

  function refreshButtons(activeMode) {
    buttons.forEach((btn) => {
      const isActive = btn.dataset.mode === activeMode;
      btn.classList.toggle('active', isActive);
      btn.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    });
  }

  function buildToggle() {
    // Prefer an explicit placeholder in the page header; otherwise create a
    // fixed control so the selector is always available.
    let container = document.getElementById('theme-toggle');
    if (!container) {
      container = document.createElement('div');
      container.id = 'theme-toggle';
      container.classList.add('theme-toggle', 'theme-toggle--floating');
      document.body.appendChild(container);
    }
    container.classList.add('theme-toggle');
    container.setAttribute('role', 'group');
    container.setAttribute('aria-label', 'Colour theme');

    buttons = MODES.map((mode) => {
      const meta = MODE_META[mode];
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'theme-toggle-btn';
      btn.dataset.mode = mode;
      btn.title = meta.label + ' theme';
      btn.setAttribute('aria-label', meta.label + ' theme');
      btn.innerHTML =
        '<span class="theme-toggle-icon" aria-hidden="true">' + meta.icon +
        '</span><span class="theme-toggle-label">' + meta.label + '</span>';
      btn.addEventListener('click', () => setMode(mode));
      container.appendChild(btn);
      return btn;
    });
  }

  function onSystemChange() {
    // Only "auto" tracks the OS; light/dark are explicit and stay put.
    if (readStoredMode() === 'auto') {
      applyMode('auto');
    }
  }

  function init() {
    buildToggle();
    applyMode(readStoredMode());
    if (media) {
      if (typeof media.addEventListener === 'function') {
        media.addEventListener('change', onSystemChange);
      } else if (typeof media.addListener === 'function') {
        media.addListener(onSystemChange); // Safari < 14 fallback
      }
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
