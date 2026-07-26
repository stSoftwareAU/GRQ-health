// Dark-mode contrast helper — resolves the colours the dark theme actually
// applies to surfaces in docs/styles.css and reports WCAG luminance/contrast
// results. Covers Bootstrap tables (Issue #165) and the "Off the Grid" MIA
// host card (Issue #170).
// Usage: deno run --allow-read=<css> dark-mode-table-check.js <path-to-css>
// Prints TEST_RESULT:<name>:<PASS|FAIL>:<detail> lines for the shell harness.

const cssPath = Deno.args[0];
if (!cssPath) {
    console.error("usage: dark-mode-table-check.js <path-to-styles.css>");
    Deno.exit(2);
}
// Strip comments first — otherwise they get swept into the selector capture.
const css = (await Deno.readTextFile(cssPath)).replace(/\/\*[\s\S]*?\*\//g, "");

// --- Minimal CSS helpers ---------------------------------------------------

// Return the declaration block for an exact selector, or null when absent.
function ruleBody(selector) {
    // Selectors are matched literally against the text preceding each `{`.
    for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
        const selectors = match[1].split(",").map((s) => s.trim().replace(/\s+/g, " "));
        if (selectors.includes(selector)) return match[2];
    }
    return null;
}

function declarations(body) {
    const out = {};
    for (const decl of body.split(";")) {
        const idx = decl.indexOf(":");
        if (idx === -1) continue;
        out[decl.slice(0, idx).trim()] = decl.slice(idx + 1).trim();
    }
    return out;
}

// Resolve `var(--x)` references against the dark palette block, one hop at a
// time, so the table rules may reuse the existing dark custom properties.
const darkPalette = declarations(ruleBody('[data-theme="dark"]') ?? "");
function resolveValue(value, depth = 0) {
    if (!value || depth > 5) return value;
    const varMatch = value.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*([^)]*))?\)$/);
    if (!varMatch) return value;
    const referenced = darkPalette[varMatch[1]] ?? varMatch[2];
    return resolveValue(referenced?.trim(), depth + 1);
}

// --- Colour maths (WCAG 2.1 relative luminance and contrast) ---------------

function parseColour(value) {
    if (!value) return null;
    const v = value.trim().toLowerCase();
    let m = v.match(/^#([0-9a-f]{3})$/);
    if (m) {
        const [r, g, b] = m[1].split("").map((c) => parseInt(c + c, 16));
        return { r, g, b, a: 1 };
    }
    m = v.match(/^#([0-9a-f]{6})$/);
    if (m) {
        return {
            r: parseInt(m[1].slice(0, 2), 16),
            g: parseInt(m[1].slice(2, 4), 16),
            b: parseInt(m[1].slice(4, 6), 16),
            a: 1,
        };
    }
    m = v.match(/^rgba?\(([^)]+)\)$/);
    if (m) {
        const parts = m[1].split(/[,/]/).map((p) => parseFloat(p.trim()));
        if (parts.length < 3 || parts.some(Number.isNaN)) return null;
        return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
    }
    return null;
}

// Composite a possibly translucent colour over an opaque backdrop.
function flatten(colour, backdrop) {
    if (colour.a >= 1) return colour;
    return {
        r: colour.r * colour.a + backdrop.r * (1 - colour.a),
        g: colour.g * colour.a + backdrop.g * (1 - colour.a),
        b: colour.b * colour.a + backdrop.b * (1 - colour.a),
        a: 1,
    };
}

function luminance(colour) {
    const channel = (c) => {
        const s = c / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * channel(colour.r) + 0.7152 * channel(colour.g) + 0.0722 * channel(colour.b);
}

function contrast(a, b) {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}

function report(name, ok, detail) {
    console.log(`TEST_RESULT:${name}:${ok ? "PASS" : "FAIL"}:${detail}`);
}

// Pull every colour token out of a `background` shorthand — including the stops
// of a linear-gradient and any layered translucent washes — so a surface built
// from a gradient can be measured at its worst (lightest) point.
function backgroundColours(value) {
    if (!value) return [];
    const tokens = value.match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|var\(\s*--[\w-]+\s*\)/g) ?? [];
    return tokens.map((t) => parseColour(resolveValue(t))).filter((c) => c !== null);
}

// The lightest layer of a surface, composited over `backdrop` — the worst case
// for light text sitting on top of it.
function lightestLayer(colours, backdrop) {
    let worst = null;
    for (const colour of colours) {
        const flat = flatten(colour, backdrop);
        if (worst === null || luminance(flat) > luminance(worst)) worst = flat;
    }
    return worst;
}

// --- Tests -----------------------------------------------------------------

// The dark page surface everything else is composited over.
const pageSurface = parseColour(resolveValue(darkPalette["--card-bg"])) ??
    { r: 35, g: 38, b: 58, a: 1 };

// --- Issue #170: the "Off the Grid" (MIA) host card ------------------------
// The base .host-card.mia rule paints a near-white mint gradient. The dark
// palette flips the card text light, so without a dark surface of its own the
// card renders light-on-light and is unreadable.
{
    const darkMiaBody = ruleBody('[data-theme="dark"] .host-card.mia');
    report(
        "dark-mia-card-rule-exists",
        darkMiaBody !== null,
        darkMiaBody !== null
            ? 'found a [data-theme="dark"] .host-card.mia rule'
            : 'no [data-theme="dark"] .host-card.mia rule — the light mint gradient wins',
    );

    // Fall back to the base rule so the contrast checks below measure whatever
    // the dark theme *actually* resolves to, not merely whether a rule exists.
    const effective = declarations(darkMiaBody ?? ruleBody(".host-card.mia") ?? "");
    const surface = lightestLayer(
        backgroundColours(effective["background"] ?? effective["background-color"]),
        pageSurface,
    );
    const cardText = parseColour(resolveValue(darkPalette["--card-text"]));
    const mutedText = parseColour(resolveValue(darkPalette["--muted-color"]));

    // 1. Hostname / values (--card-text) must meet WCAG AA on that surface.
    {
        const ratio = surface && cardText ? contrast(flatten(cardText, surface), surface) : 0;
        report(
            "mia-card-text-contrast-meets-aa",
            ratio >= 4.5,
            surface === null
                ? "the MIA card background is missing or unparseable"
                : `--card-text on the MIA card ${ratio.toFixed(2)}:1 (needs >= 4.5)`,
        );
    }

    // 2. The .text-muted labels ("OS", "Last Seen", the location line) too.
    {
        const ratio = surface && mutedText ? contrast(flatten(mutedText, surface), surface) : 0;
        report(
            "mia-card-muted-contrast-meets-aa",
            ratio >= 4.5,
            surface === null
                ? "the MIA card background is missing or unparseable"
                : `--muted-color on the MIA card ${ratio.toFixed(2)}:1 (needs >= 4.5)`,
        );
    }

    // 3. It must still read as a special card, not blend into a plain host card.
    {
        const delta = surface
            ? Math.max(
                Math.abs(surface.r - pageSurface.r),
                Math.abs(surface.g - pageSurface.g),
                Math.abs(surface.b - pageSurface.b),
            )
            : 0;
        report(
            "mia-card-stays-distinct",
            delta >= 8,
            `MIA surface differs from a plain card by ${delta.toFixed(1)}/255 (needs >= 8)`,
        );
    }

    // 4. Light mode keeps its light mint gradient — the fix supplements the
    //    base rule, it must not darken it.
    {
        const light = lightestLayer(
            backgroundColours(declarations(ruleBody(".host-card.mia") ?? "")["background"]),
            { r: 255, g: 255, b: 255, a: 1 },
        );
        const lum = light ? luminance(light) : null;
        report(
            "light-mia-card-stays-light",
            lum !== null && lum > 0.7,
            lum === null
                ? "the light .host-card.mia background is missing or unparseable"
                : `light MIA surface luminance ${lum.toFixed(4)} (needs > 0.7)`,
        );
    }
}

// --- Issue #165: Bootstrap tables ------------------------------------------

const tableBody = ruleBody('[data-theme="dark"] .table');

// 1. The dark theme must override Bootstrap's table colours at all.
report(
    "dark-table-rule-exists",
    tableBody !== null,
    tableBody !== null
        ? 'found a [data-theme="dark"] .table rule'
        : 'no [data-theme="dark"] .table rule — Bootstrap\'s white --bs-table-bg wins',
);

if (tableBody === null) Deno.exit(0);

const table = declarations(tableBody);

const cellBg = parseColour(resolveValue(table["--bs-table-bg"]));
const cellText = parseColour(resolveValue(table["--bs-table-color"]));
const stripeBg = parseColour(resolveValue(table["--bs-table-striped-bg"]));
const stripeText = parseColour(resolveValue(table["--bs-table-striped-color"]));
const borderColour = parseColour(resolveValue(table["--bs-table-border-color"]));

// 2. Cell background is dark, not the white Bootstrap default.
{
    const flat = cellBg ? flatten(cellBg, pageSurface) : null;
    const lum = flat ? luminance(flat) : null;
    report(
        "cell-background-is-dark",
        lum !== null && lum < 0.2,
        lum === null
            ? "--bs-table-bg is missing or unparseable"
            : `--bs-table-bg luminance ${lum.toFixed(4)} (needs < 0.2)`,
    );
}

// 3. Cell text is light.
{
    const lum = cellText ? luminance(flatten(cellText, pageSurface)) : null;
    report(
        "cell-text-is-light",
        lum !== null && lum > 0.4,
        lum === null
            ? "--bs-table-color is missing or unparseable"
            : `--bs-table-color luminance ${lum.toFixed(4)} (needs > 0.4)`,
    );
}

// 4. Body text meets WCAG AA (4.5:1) against the cell background.
{
    const ok = cellBg && cellText;
    const ratio = ok ? contrast(flatten(cellText, pageSurface), flatten(cellBg, pageSurface)) : 0;
    report(
        "cell-contrast-meets-aa",
        ratio >= 4.5,
        `text/background contrast ${ratio.toFixed(2)}:1 (needs >= 4.5)`,
    );
}

// 5. Striped rows stay dark too — the stripe is what made alternate rows glare.
{
    const flat = stripeBg ? flatten(stripeBg, pageSurface) : null;
    const lum = flat ? luminance(flat) : null;
    report(
        "striped-row-is-dark",
        lum !== null && lum < 0.2,
        lum === null
            ? "--bs-table-striped-bg is missing or unparseable"
            : `--bs-table-striped-bg luminance ${lum.toFixed(4)} (needs < 0.2)`,
    );
}

// 6. Striped-row text also meets WCAG AA.
{
    const text = stripeText ?? cellText;
    const ok = stripeBg && text;
    const ratio = ok ? contrast(flatten(text, pageSurface), flatten(stripeBg, pageSurface)) : 0;
    report(
        "striped-contrast-meets-aa",
        ratio >= 4.5,
        `striped text/background contrast ${ratio.toFixed(2)}:1 (needs >= 4.5)`,
    );
}

// 7. Row separators must be visible but subtle — not Bootstrap's light grey.
{
    const flat = borderColour ? flatten(borderColour, pageSurface) : null;
    const ratio = flat ? contrast(flat, flatten(cellBg ?? pageSurface, pageSurface)) : 0;
    report(
        "border-is-subtle",
        borderColour !== null && ratio < 4.5,
        borderColour === null
            ? "--bs-table-border-color is missing or unparseable"
            : `border/background contrast ${ratio.toFixed(2)}:1 (needs < 4.5, i.e. subtle)`,
    );
}

// 8. The "Log" buttons sit inside the table; once the table goes dark their
//    default mid-grey outline text must be lightened to stay readable.
{
    const btnBody = ruleBody('[data-theme="dark"] .btn-outline-secondary');
    const btn = btnBody ? declarations(btnBody) : {};
    const colour = parseColour(resolveValue(btn["--bs-btn-color"]));
    const backdrop = flatten(cellBg ?? pageSurface, pageSurface);
    const ratio = colour ? contrast(flatten(colour, backdrop), backdrop) : 0;
    report(
        "log-button-contrast-meets-aa",
        ratio >= 4.5,
        colour === null
            ? "no dark override for .btn-outline-secondary text colour"
            : `button text/table contrast ${ratio.toFixed(2)}:1 (needs >= 4.5)`,
    );
}
