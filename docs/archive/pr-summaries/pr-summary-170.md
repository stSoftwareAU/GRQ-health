# Dark mode: give `.host-card.mia` a dark surface

## Summary

The "Off the Grid" (MIA) host card hardcoded a near-white mint gradient in
`docs/styles.css`. The dark palette added by #161 flips the card's text to
`--card-text` / `--muted-color`, but the MIA card's background is a colour
literal rather than `var(--card-bg)`, so in dark mode the card rendered light
text on a light surface — the hostname, location, OS and Last Seen values were
all effectively invisible. Closes #170.

The fix adds a `[data-theme="dark"] .host-card.mia` rule alongside the existing
`.critical` / `.dead` / `.historical` dark overrides. It washes the card's own
`#20c997` teal over `var(--card-bg)` instead of over white, so the accent
identity survives while the surface follows the dark palette:

```css
[data-theme="dark"] .host-card.mia {
    background:
        linear-gradient(135deg,
            rgba(32, 201, 151, 0.04) 0%,
            rgba(32, 201, 151, 0.07) 50%,
            rgba(32, 201, 151, 0.10) 100%),
        var(--card-bg);
}
```

The left border, glow and border tint are inherited untouched from the base
rule, and the base rule itself is not modified — light mode is unchanged.

Measured contrast on the resolved dark surface:

| Text | Before | After | Needs |
| --- | --- | --- | --- |
| `--card-text` (hostname, values) | 1.17:1 | **10.24:1** | ≥ 4.5:1 |
| `--muted-color` (OS, Last Seen, location) | 2.50:1 | **4.80:1** | ≥ 4.5:1 |

## Evidence

Dark mode **before** the fix — the reported failure signature, near-white text
on the near-white mint gradient:

![MIA card in dark mode before the fix](docs/evidence/issue-170-mia-card-dark-before.png)

Dark mode **after** the fix — every line legible, teal accent retained:

![MIA card in dark mode after the fix](docs/evidence/issue-170-mia-card-dark-after.png)

Light mode is untouched:

![MIA card in light mode, unchanged](docs/evidence/issue-170-mia-card-light-unchanged.png)

Screenshots were captured against the real dashboard (`docs/index.html` served
locally with the live `docs/index.json`, where `Tinas-MacBook-Air` classifies as
MIA), driven headlessly over CDP with the theme set to dark via the #163 theme
control's `localStorage` key. Playwright MCP was not available in this session,
so headless Chromium was driven directly; the "before" shot is the same page
served with only the new `[data-theme="dark"] .host-card.mia` rule stripped out,
so the two images differ by exactly this change.

## Test Plan

`tests/dark-mode-table-check.js` — the WCAG harness introduced for #165 — is
extended with four `.host-card.mia` assertions, run by the existing
`tests/test-dark-mode-table.sh`. They resolve the colour the dark theme
*actually* applies (following `var(--x)` into the dark palette, and now
extracting every stop of a gradient or layered background so the lightest layer
is measured as the worst case), then assert on behaviour rather than on any
particular literal:

- `dark-mia-card-rule-exists` — a `[data-theme="dark"] .host-card.mia` rule is
  present. Falls back to the base rule for the checks below, so the contrast
  assertions measure what the dark theme resolves to, not merely that a rule
  exists.
- `mia-card-text-contrast-meets-aa` — ≥ 4.5:1 between the resolved surface and
  `--card-text`.
- `mia-card-muted-contrast-meets-aa` — ≥ 4.5:1 against `--muted-color`, which is
  what the `.text-muted` labels resolve to in dark mode.
- `mia-card-stays-distinct` — the surface still differs from a plain
  `var(--card-bg)` card by ≥ 8/255 on some channel, so the fix cannot be
  "solved" by flattening the card into an ordinary one.
- `light-mia-card-stays-light` — the base rule's gradient still resolves to a
  light surface (luminance > 0.7), guarding against a fix that darkens light
  mode instead of supplementing it.

Confirmed to fail before the CSS change and pass after:

```
# before
FAIL: dark-mia-card-rule-exists — no [data-theme="dark"] .host-card.mia rule
FAIL: mia-card-text-contrast-meets-aa — --card-text on the MIA card 1.17:1 (needs >= 4.5)
FAIL: mia-card-muted-contrast-meets-aa — --muted-color on the MIA card 2.50:1 (needs >= 4.5)

# after
PASS: dark-mia-card-rule-exists — found a [data-theme="dark"] .host-card.mia rule
PASS: mia-card-text-contrast-meets-aa — --card-text on the MIA card 10.24:1 (needs >= 4.5)
PASS: mia-card-muted-contrast-meets-aa — --muted-color on the MIA card 4.80:1 (needs >= 4.5)
PASS: mia-card-stays-distinct — MIA surface differs from a plain card by 16.3/255 (needs >= 8)
PASS: light-mia-card-stays-light — light MIA surface luminance 1.0000 (needs > 0.7)
```

`./quality.sh` passes: 62 tests, 0 failures.

## Scope notes

- `.host-card.mobile` and `.host-card.outdated-macos` have the same class of
  fault and are tracked separately in #171; the broader per-variant contrast
  guard is #172. Neither is touched here.
- Version bumped to `1.1.22` and synced with `./update_version.sh`, per the
  repo's version-management rule for code changes.
- No web-facing behaviour beyond the dark-mode surface changed; no new
  dependencies.
