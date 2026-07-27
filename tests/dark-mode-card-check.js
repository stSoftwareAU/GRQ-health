// Issue #172: WCAG contrast regression guard for *every* .host-card variant in
// dark mode.
//
// #161 introduced the dark palette; #165, #170 and #171 each fixed the same
// fault afterwards — a component that hardcodes a light background survives the
// `[data-theme="dark"]` switch, and the dark palette's light text then renders
// on it unreadably. This checker generalises that class of test: it *enumerates*
// the `.host-card.<variant>` rules present in docs/styles.css instead of working
// from a fixed list, so a variant added later is covered without a test edit.
//
// For each variant it resolves the background the dark theme actually applies —
// the `[data-theme="dark"]` override when present, otherwise whatever the base
// rules leave in place — composites every layer and every gradient stop over the
// dark page surface, and asserts WCAG 2.1 AA (4.5:1) against `--card-text` and
// `--muted-color`.
//
// Usage: deno run --allow-read=<css> dark-mode-card-check.js <path-to-css>
// Prints TEST_RESULT:<name>:<PASS|FAIL>:<detail> lines for the shell harness.

import {
    contrast,
    declarations,
    flatten,
    luminance,
    makeResolver,
    parseColour,
    report,
    ruleBody,
    rules,
    splitLayers,
    stripComments,
} from "./css-colour-lib.js";

const cssPath = Deno.args[0];
if (!cssPath) {
    console.error("usage: dark-mode-card-check.js <path-to-styles.css>");
    Deno.exit(2);
}
const css = stripComments(await Deno.readTextFile(cssPath));

const DARK = '[data-theme="dark"]';
const NAME = "dark-mode-host-cards";
const AA = 4.5;

const darkPalette = declarations(ruleBody(css, DARK) ?? "");
const resolve = makeResolver(darkPalette);

// --- Variant enumeration ---------------------------------------------------

// Every `.host-card.<variant>` rule in the stylesheet, whether it appears in the
// base cascade or only under the dark theme. Pseudo-element decoration rules
// (`.host-card.mia::before`) and compound selectors paint no card surface, so
// only the bare variant selector counts.
function discoverVariants() {
    const found = new Set();
    for (const rule of rules(css)) {
        for (const selector of rule.selectors) {
            const bare = selector.startsWith(`${DARK} `)
                ? selector.slice(DARK.length + 1)
                : selector;
            const match = bare.match(/^\.host-card\.([\w-]+)$/);
            if (match) found.add(match[1]);
        }
    }
    return [...found].sort();
}

const variants = discoverVariants();
report(
    `${NAME}-variants-discovered`,
    variants.length > 0,
    variants.length > 0
        ? `enumerated ${variants.length} .host-card variants from the stylesheet: ${
            variants.join(", ")
        }`
        : "no .host-card.<variant> rules found — the sweep would pass by vacuity",
);

// --- Colours the dark theme resolves to ------------------------------------

// The dark page surface every card is composited over.
const pageSurface = parseColour(resolve(darkPalette["--card-bg"]));
const textColours = [
    ["card-text", parseColour(resolve(darkPalette["--card-text"]))],
    ["muted-color", parseColour(resolve(darkPalette["--muted-color"]))],
];

// Fail loud rather than silently skipping the sweep when the palette moves.
if (pageSurface === null || textColours.some(([, colour]) => colour === null)) {
    report(
        `${NAME}-dark-palette-resolves`,
        false,
        `${DARK} must define parseable --card-bg, --card-text and --muted-color`,
    );
    Deno.exit(0);
}

// The background the dark theme actually applies to a variant, and where it
// came from. A variant with no surface of its own inherits the base `.host-card`
// background, which is what makes an unfixed light literal show up here.
function effectiveBackground(variant) {
    const sources = [
        [`${DARK} .host-card.${variant}`, ruleBody(css, `${DARK} .host-card.${variant}`)],
        [`.host-card.${variant}`, ruleBody(css, `.host-card.${variant}`)],
        [`${DARK} .host-card`, ruleBody(css, `${DARK} .host-card`)],
        [".host-card", ruleBody(css, ".host-card")],
    ];
    for (const [selector, body] of sources) {
        if (body === null) continue;
        const decls = declarations(body);
        const value = decls["background"] ?? decls["background-color"];
        if (value) return { selector, value };
    }
    return null;
}

// Every colour a surface paints, each composited over what sits beneath it:
// layers bottom-up (CSS lists them top-most first) and gradients stop by stop,
// so a gradient that starts dark and ends light is still measured at its light
// end. Translucent layers are composited, never treated as opaque — these
// backgrounds are `rgba(...)` washes whose alpha is the whole point.
function surfaceStops(value) {
    const layers = splitLayers(value);
    const stops = [];
    let backdrop = pageSurface;
    for (let i = layers.length - 1; i >= 0; i--) {
        const tokens = layers[i].match(/#[0-9a-fA-F]{3,8}\b|rgba?\([^)]*\)|var\(\s*--[\w-]+\s*\)/g);
        const colours = (tokens ?? []).map((t) => parseColour(resolve(t))).filter((c) => c !== null);
        if (colours.length === 0) continue;
        const flats = colours.map((colour, idx) => ({
            colour: flatten(colour, backdrop),
            label: layers.length > 1 ? `layer ${i + 1} stop ${idx + 1}` : `stop ${idx + 1}`,
        }));
        stops.push(...flats);
        // Worst case for light text is the lightest thing showing through.
        backdrop = flats.reduce(
            (worst, s) => luminance(s.colour) > luminance(worst) ? s.colour : worst,
            flats[0].colour,
        );
    }
    return stops;
}

// --- The sweep -------------------------------------------------------------

for (const variant of variants) {
    const background = effectiveBackground(variant);
    const stops = background ? surfaceStops(background.value) : [];

    if (stops.length === 0) {
        for (const [label] of textColours) {
            report(
                `${NAME}-${variant}-${label}`,
                false,
                background === null
                    ? `.host-card.${variant} resolves to no background at all in dark mode`
                    : `.host-card.${variant} background from ${background.selector} is unparseable`,
            );
        }
        continue;
    }

    for (const [label, textColour] of textColours) {
        // Every stop is measured; the worst one decides the verdict.
        let worst = null;
        for (const stop of stops) {
            const ratio = contrast(flatten(textColour, stop.colour), stop.colour);
            if (worst === null || ratio < worst.ratio) worst = { ratio, label: stop.label };
        }
        report(
            `${NAME}-${variant}-${label}`,
            worst.ratio >= AA,
            `--${label} on .host-card.${variant} (${background.selector}) ` +
                `${worst.ratio.toFixed(2)}:1 at worst of ${stops.length} stop(s), ` +
                `${worst.label} (needs >= ${AA})`,
        );
    }
}
