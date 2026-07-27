# Dark mode: give `.host-card.mobile` and `.host-card.outdated-macos` dark surfaces

## Summary

`.host-card.mia` was not the only host-card variant that hardcoded a light
background with no dark-theme override. `.host-card.mobile` (`docs/styles.css`
:389) and `.host-card.outdated-macos` (:420) paint the same near-white
gradients, and both land on **active** cards — `docs/dashboard.js:1227` adds
`mobile` for any host with `data.mobile`, and `:1239` adds `outdated-macos`
whenever a macOS update is pending. In dark mode the palette flips the card text
to `--card-text` / `--muted-color`, so an online MacBook or any Mac with a
pending OS update rendered light-on-light and was unreadable. Closes #171.

The fix matches the surface treatment the `.mia` fix (#170) adopted: wash each
variant's own `#fd7e14` orange over `var(--card-bg)` instead of over white, so
the accent identity (left border, glow, border tint) is still inherited from the
untouched base rule and light mode is unchanged.

```css
[data-theme="dark"] .host-card.mobile {
    background:
        linear-gradient(135deg,
            rgba(253, 126, 20, 0.05) 0%,
            rgba(253, 126, 20, 0.09) 50%,
            rgba(253, 126, 20, 0.12) 100%),
        var(--card-bg);
}

[data-theme="dark"] .host-card.outdated-macos {
    background:
        linear-gradient(135deg,
            rgba(253, 126, 20, 0.02) 0%,
            rgba(253, 126, 20, 0.04) 50%,
            rgba(253, 126, 20, 0.06) 100%),
        var(--card-bg);
}
```

The two washes are pitched at different strengths deliberately: both variants
share the same orange accent, so a single shared surface would make an "island"
host indistinguishable from a Mac with a pending update.

Measured contrast on the resolved dark surfaces:

| Card | Text | Before | After | Needs |
| --- | --- | --- | --- | --- |
| `.mobile` | `--card-text` | 1.17:1 | **10.25:1** | ≥ 4.5:1 |
| `.mobile` | `--muted-color` | 2.50:1 | **4.81:1** | ≥ 4.5:1 |
| `.outdated-macos` | `--card-text` | 1.17:1 | **11.26:1** | ≥ 4.5:1 |
| `.outdated-macos` | `--muted-color` | 2.50:1 | **5.28:1** | ≥ 4.5:1 |

Distinguishability, measured as the largest per-channel difference between the
resolved surfaces (threshold 8/255):

| Pair | Delta |
| --- | --- |
| `.mobile` vs a plain `.host-card` | 26.2/255 |
| `.outdated-macos` vs a plain `.host-card` | 13.1/255 |
| `.mobile` vs `.outdated-macos` | 13.1/255 |
| `.mobile` vs `.mia` | 26.5/255 |

The "Update" badge inside `.outdated-macos` cards paints its own opaque
`#fd7e14` background, so it stays legible as long as that background separates
from the card surface behind it — it now clears WCAG 1.4.11 (non-text UI
component) at **5.33:1** against the new surface, up from 2.48:1 against the old
light literal.

`.mobile` and `.mia` can co-occur on one element. `[data-theme="dark"]
.host-card.mobile` is later in source order, so it wins — and its surface is the
one measured at 10.25:1 above, so the combined case is readable too.

## Evidence

Dark mode **before** the fix — GRQ-23 (mobile) and GRQ-21 (pending macOS
update) render near-white text on near-white gradients; the hostnames, OS,
disk, CPU and GPU values are all effectively invisible:

![Mobile and outdated-macOS cards in dark mode before the fix](docs/evidence/issue-171-dark-before.png)

Dark mode **after** the fix — every line legible on both cards, the orange
accent retained, and the two variants still tellable apart from each other and
from the plain GRQ-19 / GRQ-12 cards beside them. The orange "Update" badge on
GRQ-21 still reads clearly:

![Mobile and outdated-macOS cards in dark mode after the fix](docs/evidence/issue-171-dark-after.png)

Light mode is untouched — the warm cream `.mobile` gradient and the near-white
`.outdated-macos` gradient are exactly as before:

![Mobile and outdated-macOS cards in light mode, unchanged](docs/evidence/issue-171-light-unchanged.png)

Screenshots were captured against the real dashboard (`docs/index.html` served
locally over the live `docs/index.json`, with GRQ-23 forced to `mobile` and
GRQ-21's `os_version` set behind the fleet's latest so both variants render on
active cards at once — the verification scenario from the issue). Playwright MCP
was not available in this session, so `chrome-headless-shell` was driven
directly over CDP with the theme set through the #163 control's own
`localStorage` key. The "before" shot is the same page served with only the new
`[data-theme="dark"]` rules stripped out, so the two images differ by exactly
this change.

## Test Plan

`tests/dark-mode-table-check.js` — the WCAG harness from #165, driven by
`tests/test-dark-mode-table.sh` and run by `./quality.sh` — resolves the colours
the dark theme *actually* applies (following `var(--x)` into the dark palette,
compositing translucent gradient stops over the card surface) and asserts on
measured luminance and contrast, not on colour literals. Retuning the palette
keeps it passing; regressing to a light surface does not.

The per-variant checks the `.mia` fix introduced are now driven by a shared
`checkHostCardVariant()` helper, so `.mia`, `.mobile` and `.outdated-macos` are
all covered by the same four assertions with no duplication:

- `dark-<variant>-card-rule-exists` — the `[data-theme="dark"]` override is present.
- `<variant>-card-text-contrast-meets-aa` — `--card-text` ≥ 4.5:1 on the resolved surface.
- `<variant>-card-muted-contrast-meets-aa` — `--muted-color` ≥ 4.5:1 on the resolved surface.
- `<variant>-card-stays-distinct` — the surface still differs from a plain `.host-card`.
- `light-<variant>-card-stays-light` — light mode keeps its light gradient.

New assertions added for this issue:

- `dark-mobile-vs-outdated-macos-stay-distinguishable`
- `dark-mobile-vs-mia-stay-distinguishable`
- `update-badge-stands-out-on-outdated-card`

All eight new assertions fail against the unfixed CSS (`8 failed / 18 passed`)
and pass after it (`26 passed / 0 failed`). `./quality.sh` passes end to end:
62/62.

Version bumped to 1.1.23 so the changed `styles.css` busts the service-worker
cache.
