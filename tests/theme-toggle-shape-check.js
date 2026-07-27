// Issue #178: a grey square was painted behind the circular theme button in
// dark mode.
//
// The control is a circular 38px button (Issue #163) inside a plain container
// div. A leftover rule from the pre-#163 multi-button pill control painted a
// light scrim on that *container*, which has no border-radius — so on the dark
// page a grey square showed around the moon icon.
//
// This checker resolves the styles the browser actually applies, by running a
// small cascade over docs/styles.css + docs/theme.css in load order (selector
// matching, specificity, source order) against the element tree theme.js really
// builds. It then asserts on the resulting *appearance*:
//
//   * the container must not paint a perceptible rectangle behind the button —
//     either it is transparent, or it is rounded into the same circle;
//   * the button itself must stay a visible circle in both themes.
//
// It also loads docs/theme.js against a stub DOM to collect the classes the
// controller really applies, and fails on any toggle rule keyed off a class
// that is never applied (dead CSS, e.g. the removed `.theme-toggle-btn.active`).
//
// Usage: deno run --allow-read=<docs dir> theme-toggle-shape-check.js <docs-dir>
// Prints TEST_RESULT:<name>:<PASS|FAIL>:<detail> lines for the shell harness.

import {
    channelDelta,
    declarations,
    flatten,
    makeResolver,
    parseColour,
    report,
    ruleBody,
    rules,
    splitLayers,
    stripComments,
} from "./css-colour-lib.js";

const docsDir = Deno.args[0];
if (!docsDir) {
    console.error("usage: theme-toggle-shape-check.js <docs-dir>");
    Deno.exit(2);
}

// The button is 38px across, so anything at or above half that rounds it fully.
const BUTTON_SIZE = 38;
// Largest per-channel difference the eye reads as "same colour as the page".
const IMPERCEPTIBLE = 6;
// A visible button needs to stand off the page by clearly more than that.
const VISIBLE = 12;

// --- Tiny cascade engine ---------------------------------------------------

function parseCompound(text) {
    return {
        classes: [...text.matchAll(/\.([\w-]+)/g)].map((m) => m[1]),
        attrs: Object.fromEntries(
            [...text.matchAll(/\[([\w-]+)="([^"]*)"\]/g)].map((m) => [m[1], m[2]]),
        ),
        pseudos: [...text.matchAll(/::?([\w-]+)/g)].map((m) => m[1]),
        raw: text,
    };
}

// Descendant combinators only — that is all these stylesheets use.
function parseSelector(selector) {
    return selector.split(/\s+/).filter(Boolean).map(parseCompound);
}

function specificity(compounds) {
    let b = 0;
    for (const c of compounds) {
        b += c.classes.length + Object.keys(c.attrs).length + c.pseudos.length;
    }
    return b;
}

function matchesCompound(compound, node, pseudoState) {
    if (!compound.classes.every((c) => node.classes.includes(c))) return false;
    for (const [name, value] of Object.entries(compound.attrs)) {
        if (node.attrs[name] !== value) return false;
    }
    return compound.pseudos.every((p) => pseudoState.includes(p));
}

// `element` plus its ancestors (root first). Matches right-to-left like a browser.
function matchesSelector(compounds, element, ancestors, pseudoState) {
    const last = compounds[compounds.length - 1];
    if (!matchesCompound(last, element, pseudoState)) return false;
    let remaining = compounds.slice(0, -1);
    for (let i = ancestors.length - 1; i >= 0 && remaining.length; i--) {
        // Ancestors are never in a pseudo-state in the scenarios we model.
        if (matchesCompound(remaining[remaining.length - 1], ancestors[i], [])) {
            remaining = remaining.slice(0, -1);
        }
    }
    return remaining.length === 0;
}

// Merge every matching declaration in cascade order: specificity, then source.
function computeStyle(sheets, element, ancestors, pseudoState = []) {
    const matched = [];
    let order = 0;
    for (const css of sheets) {
        for (const rule of rules(css)) {
            for (const selector of rule.selectors) {
                const compounds = parseSelector(selector);
                if (matchesSelector(compounds, element, ancestors, pseudoState)) {
                    matched.push({ spec: specificity(compounds), order, body: rule.body });
                }
                order++;
            }
        }
    }
    matched.sort((a, b) => a.spec - b.spec || a.order - b.order);
    const style = {};
    for (const rule of matched) Object.assign(style, declarations(rule.body));
    return style;
}

// --- Appearance helpers ----------------------------------------------------

// The opaque colour a background paints, composited over `backdrop`. Returns
// null when nothing is painted (no declaration, `none`, or fully transparent).
function paintedColour(style, resolve, backdrop) {
    const raw = resolve(style["background"] ?? style["background-color"] ?? "");
    if (!raw || raw === "none" || raw === "transparent") return null;
    let result = null;
    // CSS paints later layers underneath, so composite from the bottom up.
    for (const layer of splitLayers(raw).reverse()) {
        const colour = parseColour(resolve(layer));
        if (!colour || colour.a === 0) continue;
        result = flatten(colour, result ?? backdrop);
    }
    return result;
}

// Does a border-radius round the box into the button's circle?
function roundsToCircle(value) {
    if (!value) return false;
    const percent = value.match(/([\d.]+)%/);
    if (percent) return parseFloat(percent[1]) >= 50;
    const px = value.match(/([\d.]+)px/);
    return px ? parseFloat(px[1]) >= BUTTON_SIZE / 2 : false;
}

// --- Stub DOM: which classes does theme.js actually apply? -----------------

function makeElement(tag) {
    const node = {
        tagName: tag,
        classes: new Set(),
        dataset: {},
        style: {},
        children: [],
        innerHTML: "",
        classList: {
            add: (...names) => names.forEach((n) => node.classes.add(n)),
            remove: (...names) => names.forEach((n) => node.classes.delete(n)),
            contains: (n) => node.classes.has(n),
        },
        setAttribute: (name, value) => {
            if (name === "class") {
                node.classes = new Set(String(value).split(/\s+/).filter(Boolean));
            }
            node.attrs[name] = value;
        },
        getAttribute: (name) => node.attrs[name] ?? null,
        addEventListener: (_type, handler) => node.handlers.push(handler),
        appendChild: (child) => {
            node.children.push(child);
            return child;
        },
        handlers: [],
        attrs: {},
    };
    Object.defineProperty(node, "className", {
        get: () => [...node.classes].join(" "),
        set: (value) => {
            node.classes = new Set(String(value).split(/\s+/).filter(Boolean));
        },
    });
    return node;
}

// Run theme.js against a stub DOM and return every class it ever puts on the
// toggle container or button, across a full cycle of taps.
async function collectAppliedClasses(themeJsPath, withPlaceholder) {
    const placeholder = makeElement("div");
    if (withPlaceholder) placeholder.classes.add("theme-toggle");
    const body = makeElement("body");
    const root = makeElement("html");
    const stored = { "grq-theme": null };
    const applied = new Set();

    const document = {
        documentElement: root,
        body,
        readyState: "complete",
        getElementById: (id) => (withPlaceholder && id === "theme-toggle" ? placeholder : null),
        querySelector: () => null,
        createElement: makeElement,
        addEventListener: () => {},
    };
    const globals = {
        document,
        window: { matchMedia: () => ({ matches: false, addEventListener: () => {} }) },
        localStorage: {
            getItem: (k) => stored[k] ?? null,
            setItem: (k, v) => {
                stored[k] = v;
            },
        },
    };
    for (const [name, value] of Object.entries(globals)) globalThis[name] = value;
    try {
        // Cache-bust so both placeholder scenarios genuinely re-execute.
        await import(`${themeJsPath}#${withPlaceholder ? "header" : "floating"}`);
        const container = withPlaceholder ? placeholder : body.children[0];
        const record = () => {
            container.classes.forEach((c) => applied.add(c));
            container.children.forEach((child) => child.classes.forEach((c) => applied.add(c)));
        };
        record();
        // Three taps walk the whole light -> dark -> auto cycle.
        for (let i = 0; i < 3; i++) {
            container.children.forEach((child) => child.handlers.forEach((h) => h()));
            record();
        }
    } finally {
        for (const name of Object.keys(globals)) delete globalThis[name];
    }
    return applied;
}

// --- Checks ----------------------------------------------------------------

const styles = stripComments(await Deno.readTextFile(`${docsDir}/styles.css`));
const theme = stripComments(await Deno.readTextFile(`${docsDir}/theme.css`));
// index.html loads styles.css first, then theme.css.
const SHEETS = [styles, theme];

const THEMES = [
    { name: "dark", pageVar: "--page-bg" },
    { name: "light", pageVar: "--page-bg" },
];

for (const { name, pageVar } of THEMES) {
    const palette = declarations(
        ruleBody(styles, name === "dark" ? '[data-theme="dark"]' : ":root") ?? "",
    );
    const resolve = makeResolver(palette);
    // The page gradient's darkest/lightest stop is the backdrop everything sits on.
    const pageLayers = splitLayers(resolve(palette[pageVar] ?? ""));
    const stops = (pageLayers.join(",").match(/#[0-9a-fA-F]{3,6}|rgba?\([^)]*\)/g) ?? [])
        .map(parseColour).filter(Boolean);
    const backdrop = stops[0] ?? { r: 255, g: 255, b: 255, a: 1 };

    const root = { classes: [], attrs: { "data-theme": name } };
    const header = { classes: ["header"], attrs: {} };
    const container = { classes: ["theme-toggle"], attrs: { id: "theme-toggle" } };
    const button = { classes: ["theme-toggle-btn"], attrs: {} };
    const ancestors = [root, header];

    // 1. The container must not show as a square behind the round button.
    const containerStyle = computeStyle(SHEETS, container, ancestors);
    const containerPaint = paintedColour(containerStyle, resolve, backdrop);
    const containerDelta = containerPaint ? channelDelta(containerPaint, backdrop) : 0;
    const rounded = roundsToCircle(containerStyle["border-radius"]);
    report(
        `container-no-square-${name}`,
        containerDelta <= IMPERCEPTIBLE || rounded,
        containerPaint
            ? `container paints ${JSON.stringify(containerStyle["background"])} ` +
                `(delta ${containerDelta.toFixed(1)} from page, border-radius ` +
                `${containerStyle["border-radius"] ?? "none"})`
            : "container paints nothing behind the button",
    );

    // 2. The button itself must still read as a visible circle.
    const buttonStyle = computeStyle(SHEETS, button, [...ancestors, container]);
    const buttonPaint = paintedColour(buttonStyle, resolve, backdrop);
    const buttonDelta = buttonPaint ? channelDelta(buttonPaint, backdrop) : 0;
    report(
        `button-visible-${name}`,
        buttonDelta >= VISIBLE,
        `button stands off the page by ${buttonDelta.toFixed(1)} per channel`,
    );
    report(
        `button-circular-${name}`,
        roundsToCircle(buttonStyle["border-radius"]),
        `button border-radius is ${buttonStyle["border-radius"] ?? "none"}`,
    );
}

// 3. No toggle rule may key off a class the controller never applies.
const themeJsPath = new URL(`file://${await Deno.realPath(`${docsDir}/theme.js`)}`).href;
const appliedClasses = new Set([
    ...(await collectAppliedClasses(themeJsPath, true)),
    ...(await collectAppliedClasses(themeJsPath, false)),
]);
// The icon span is written as innerHTML, which the stub DOM does not parse.
appliedClasses.add("theme-toggle-icon");

const deadClasses = new Set();
for (const css of SHEETS) {
    for (const rule of rules(css)) {
        for (const selector of rule.selectors) {
            for (const compound of parseSelector(selector)) {
                if (!compound.classes.some((c) => c.startsWith("theme-toggle"))) continue;
                for (const cls of compound.classes) {
                    if (!appliedClasses.has(cls)) deadClasses.add(`${cls} (in "${selector}")`);
                }
            }
        }
    }
}
report(
    "no-dead-toggle-rules",
    deadClasses.size === 0,
    deadClasses.size === 0
        ? `every toggle rule keys off a class theme.js applies (${
            [...appliedClasses].sort().join(", ")
        })`
        : `dead selectors target classes theme.js never applies: ${[...deadClasses].join("; ")}`,
);
