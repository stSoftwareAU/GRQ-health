# Dark mode: remove the grey square behind the circular theme button (Issue #178)

## Summary

In dark mode the dashboard painted a grey square behind the circular theme
button, visible as a box around the moon icon. Since Issue #163 the control is a
single 38px circular button styled entirely by `docs/theme.css`, but two rules
left over from the old multi-button pill control survived in `docs/styles.css`:

- `[data-theme="dark"] .theme-toggle` put a `rgba(255, 255, 255, 0.12)` scrim on
  the **container** div, which has no `border-radius` — hence the square.
- `[data-theme="dark"] .theme-toggle-btn.active` was dead: since #163 `theme.js`
  tracks the active mode with `data-mode`, never an `active` class.

Both rules are deleted, so the container renders transparent and only
`theme.css` styles the control. Light mode and the cycling behaviour are
unchanged; `simple.html` and `log-viewer.html` never loaded `styles.css`, so
they were already unaffected. The version is bumped to 1.1.26 so the
`styles.css?v=` cache-buster refreshes for returning visitors.

Closes #178.

## Evidence

**No browser screenshot was possible on this build host** — Playwright MCP is
not available in this run and no Chrome/Chromium binary is installed, so
`browser_navigate` / `browser_take_screenshot` could not run. Instead the fix is
verified by resolving the styles the browser would actually apply, and the
illustration below is drawn from those computed values (it is a derived
illustration, not a screenshot):

![Dark-mode theme control before and after, drawn from the computed CSS values](docs/evidence/issue-178-theme-toggle.svg)

`tests/theme-toggle-shape-check.js` runs a small cascade (selector matching,
specificity, source order) over `docs/styles.css` + `docs/theme.css` in the order
`index.html` loads them, against the element tree `docs/theme.js` really builds,
and measures the result.

Before the fix:

```
FAIL: container-no-square-dark — container paints "rgba(255, 255, 255, 0.12)"
      (delta 27.5 from page, border-radius none)
FAIL: no-dead-toggle-rules — dead selectors target classes theme.js never
      applies: active (in "[data-theme="dark"] .theme-toggle-btn.active")
Passed: 5  Failed: 2
```

After the fix:

```
PASS: container-no-square-dark — container paints nothing behind the button
PASS: button-visible-dark — button stands off the page by 36.6 per channel
PASS: button-circular-dark — button border-radius is 999px
PASS: container-no-square-light — container paints nothing behind the button
PASS: button-visible-light — button stands off the page by 65.5 per channel
PASS: button-circular-light — button border-radius is 999px
PASS: no-dead-toggle-rules — every toggle rule keys off a class theme.js applies
Passed: 7  Failed: 0
```

Full gate: `./quality.sh` — 65 tests, 65 passed, 0 failed.

## Test Plan

Added `tests/test-theme-toggle-shape.sh` and its checker
`tests/theme-toggle-shape-check.js` (7 assertions, failing before this change
and passing after). The assertions are on appearance, not on the presence of any
particular rule, so an alternative fix — for example rounding the container
instead of clearing it — would also pass:

- `container-no-square-{dark,light}` — the container must paint nothing
  perceptible behind the button (≤6 per-channel from the page) **unless** its
  `border-radius` rounds it into the same circle.
- `button-visible-{dark,light}` — regression guard: the button must still stand
  clearly off the page (≥12 per channel), so the square cannot be removed by
  clearing the button's own background.
- `button-circular-{dark,light}` — the button's `border-radius` still rounds it
  fully.
- `no-dead-toggle-rules` — `theme.js` is loaded against a stub DOM and tapped
  through a full light → dark → auto cycle, in both the header-placeholder and
  floating layouts, to collect the classes it genuinely applies; any toggle rule
  keyed off a class outside that set (such as the removed `.active`) fails.

No existing tests were modified or removed.
