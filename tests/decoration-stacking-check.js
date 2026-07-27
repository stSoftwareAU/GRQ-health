// Issue #173: the decorative host-card emoji must paint *behind* the card's
// content, and must not intercept pointer or touch events.
//
// `.host-card.mia::before` (🌐) was an absolutely-positioned pseudo-element at
// `z-index: 1`, anchored to the same top-right corner the `.health-status`
// badge occupies. The badge is in normal flow, so a positioned decoration with
// a non-negative z-index always paints over it and the "OFF THE GRID" text was
// obscured.
//
// This checker resolves the CSS painting order (CSS 2.1 Appendix E) for every
// `.host-card.<variant>::before/::after` decoration it finds in a stylesheet
// and compares it with the `.health-status` badge, rather than looking for any
// particular declaration. Nudging the emoji's `right` offset, or swapping
// `z-index: 1` for `z-index: 0`, does not satisfy it — only the decoration
// genuinely painting below the badge does.
//
// Usage: deno run --allow-read=<css> decoration-stacking-check.js <css>

import { declarations, report, rules, stripComments } from "./css-colour-lib.js";

const cssPath = Deno.args[0];
if (!cssPath) {
    console.error("usage: decoration-stacking-check.js <path-to-styles.css>");
    Deno.exit(2);
}
const css = stripComments(await Deno.readTextFile(cssPath));
const allRules = [...rules(css)];

const NAME = "decoration-stacking";
const DARK = '[data-theme="dark"]';

// Theme-prefixed rules style the same element, so they take part in the same
// cascade for our purposes.
function bare(selector) {
    return selector.startsWith(`${DARK} `) ? selector.slice(DARK.length + 1) : selector;
}

// Declarations from every rule matching `selector`, merged in source order so
// later rules win — a rough but sufficient stand-in for the cascade, since all
// the selectors involved here carry comparable specificity.
function resolved(selector) {
    const merged = {};
    for (const rule of allRules) {
        if (!rule.selectors.some((s) => bare(s) === selector)) continue;
        Object.assign(merged, declarations(rule.body));
    }
    return merged;
}

// --- Decoration enumeration ------------------------------------------------

// Enumerated from the stylesheet, not from a fixed list, so a newly decorated
// variant is covered without editing this checker.
function discoverDecorations() {
    const found = new Set();
    for (const rule of allRules) {
        for (const selector of rule.selectors) {
            const match = bare(selector).match(/^\.host-card\.([\w-]+)::(before|after)$/);
            if (match) found.add(`${match[1]}::${match[2]}`);
        }
    }
    return [...found].sort();
}

const decorations = discoverDecorations();
report(
    `${NAME}-decorations-discovered`,
    decorations.length > 0,
    decorations.length > 0
        ? `enumerated ${decorations.length} host-card decoration(s): ${decorations.join(", ")}`
        : "no .host-card.<variant>::before/::after rules found — the sweep would pass by vacuity",
);

// --- Painting order --------------------------------------------------------

// Where an element lands in its stacking context's painting order. Ranks are
// comparable numbers, not z-index values: in-flow content sits above every
// negative-z positioned box and below every non-negative one, which is exactly
// why dropping the decorations to `z-index: 0` would not have fixed anything.
function paintRank(decl) {
    const position = decl["position"] ?? "static";
    const raw = decl["z-index"];
    const z = raw !== undefined && /^-?\d+$/.test(raw.trim()) ? parseInt(raw, 10) : null;

    if (position === "static") {
        // z-index does not apply to static boxes; they paint with the in-flow content.
        return { rank: 0, layer: "in-flow content (position: static)" };
    }
    if (z === null) return { rank: 0.5, layer: `positioned, z-index auto (${position})` };
    if (z < 0) return { rank: z, layer: `positioned, z-index ${z} (${position})` };
    if (z === 0) return { rank: 0.5, layer: `positioned, z-index 0 (${position})` };
    return { rank: z, layer: `positioned, z-index ${z} (${position})` };
}

// A negative-z decoration only stays inside its card if the card is a stacking
// context; otherwise it escapes to an ancestor context and paints behind the
// card's own background, i.e. disappears.
function establishesStackingContext(decl) {
    const reasons = [];
    const has = (prop, value) => (decl[prop] ?? "").trim() === value;
    const set = (prop) => {
        const v = (decl[prop] ?? "none").trim();
        return v !== "none" && v !== "";
    };

    if (has("isolation", "isolate")) reasons.push("isolation: isolate");
    if (["fixed", "sticky"].includes((decl["position"] ?? "static").trim())) {
        reasons.push(`position: ${decl["position"].trim()}`);
    }
    if (
        ["relative", "absolute"].includes((decl["position"] ?? "static").trim()) &&
        /^-?\d+$/.test((decl["z-index"] ?? "auto").trim())
    ) {
        reasons.push(`position: ${decl["position"].trim()} with z-index: ${decl["z-index"].trim()}`);
    }
    for (const prop of ["transform", "filter", "backdrop-filter", "perspective", "contain", "mix-blend-mode"]) {
        if (set(prop)) reasons.push(`${prop}: ${decl[prop].trim()}`);
    }
    const opacity = parseFloat(decl["opacity"] ?? "1");
    if (!Number.isNaN(opacity) && opacity < 1) reasons.push(`opacity: ${opacity}`);

    return reasons;
}

// --- The sweep -------------------------------------------------------------

for (const key of decorations) {
    const [variant, pseudo] = key.split("::");
    const decoration = resolved(`.host-card.${variant}::${pseudo}`);
    const card = { ...resolved(".host-card"), ...resolved(`.host-card.${variant}`) };
    // The badge carries the variant as a class of its own (`.health-status.mia`).
    const badge = { ...resolved(".health-status"), ...resolved(`.health-status.${variant}`) };

    const deco = paintRank(decoration);
    const badgeLayer = paintRank(badge);

    report(
        `${NAME}-${variant}-${pseudo}-behind-badge`,
        badgeLayer.rank > deco.rank,
        `.host-card.${variant}::${pseudo} is ${deco.layer}; ` +
            `.health-status is ${badgeLayer.layer} — ` +
            (badgeLayer.rank > deco.rank
                ? "the badge paints above the decoration"
                : "the decoration paints over the badge and obscures the status text"),
    );

    const contexts = establishesStackingContext(card);
    report(
        `${NAME}-${variant}-${pseudo}-stays-in-card`,
        deco.rank >= 0 || contexts.length > 0,
        deco.rank >= 0
            ? `.host-card.${variant}::${pseudo} has no negative z-index, so it cannot escape the card`
            : contexts.length > 0
            ? `.host-card.${variant} is a stacking context (${contexts.join(", ")}), ` +
                "so the decoration paints above the card background"
            : `.host-card.${variant} is not a stacking context, so ${deco.layer} ` +
                "escapes the card and paints behind its background",
    );

    const pointerEvents = (decoration["pointer-events"] ?? "auto").trim();
    report(
        `${NAME}-${variant}-${pseudo}-pointer-events`,
        pointerEvents === "none",
        `.host-card.${variant}::${pseudo} has pointer-events: ${pointerEvents}` +
            (pointerEvents === "none" ? "" : " — the decoration can swallow taps on the card"),
    );

    const animation = (decoration["animation"] ?? "none").trim();
    report(
        `${NAME}-${variant}-${pseudo}-animation`,
        animation !== "none" && animation !== "",
        animation !== "none" && animation !== ""
            ? `.host-card.${variant}::${pseudo} still animates (${animation})`
            : `.host-card.${variant}::${pseudo} lost its animation`,
    );
}
