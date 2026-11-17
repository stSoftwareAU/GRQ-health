// Issue #174: the host-card hostname must truncate with an ellipsis on a single
// line instead of wrapping onto a second one.
//
// `.host-card h5` carried `overflow: hidden; text-overflow: ellipsis` without
// `white-space: nowrap`, so the text wrapped rather than overflowing and the
// ellipsis never fired — `Tinas-MacBook-Air` dropped "Air" onto a second line
// and pushed the header into the "OFF THE GRID" badge (Issue #169).
//
// This checker locates, per host-card header template in dashboard.js, the
// element that actually holds the hostname *text run*, resolves the CSS that
// applies to that element, and asks whether the resulting box can truncate.
// It is not a search for a declaration in a fixed selector: moving the rule,
// renaming the class, or restructuring the header is fine as long as the
// hostname text still lands in a truncating box with its badges intact.
//
// Usage: deno run --allow-read hostname-truncation-check.js <styles.css> <dashboard.js>

import { declarations, report, rules, stripComments } from "./css-colour-lib.js";

const [cssPath, jsPath] = Deno.args;
if (!cssPath || !jsPath) {
    console.error("usage: hostname-truncation-check.js <styles.css> <dashboard.js>");
    Deno.exit(2);
}

const css = stripComments(await Deno.readTextFile(cssPath));
const js = await Deno.readTextFile(jsPath);
const allRules = [...rules(css)];
const NAME = "hostname-truncation";
const DARK = '[data-theme="dark"]';

// Theme-prefixed rules style the same element, so they join the same cascade.
const bare = (selector) => selector.startsWith(`${DARK} `) ? selector.slice(DARK.length + 1) : selector;

// Declarations from every rule whose selector is in `candidates`, merged in
// source order so later rules win — a sufficient stand-in for the cascade here,
// where the selectors involved carry comparable specificity.
function resolved(candidates) {
    const wanted = new Set(candidates);
    const merged = {};
    for (const rule of allRules) {
        if (!rule.selectors.some((s) => wanted.has(bare(s)))) continue;
        Object.assign(merged, declarations(rule.body));
    }
    return merged;
}

// --- Header template discovery ---------------------------------------------

// The hostname text run, however the template spells it.
const HOSTNAME_TOKEN = /\$\{\s*(?:safeHostname|escapeHtml\(\s*hostname\s*\))\s*\}/;

const attr = (tag, name) => tag.match(new RegExp(`${name}="([^"]*)"`))?.[1] ?? null;
const classesOf = (tag) => (attr(tag, "class") ?? "").split(/\s+/).filter(Boolean);

// Walk the header's inner markup and return the innermost element open at the
// point the hostname text appears, plus every other element in the header.
function analyseHeader(h5Tag, inner) {
    const hostnameAt = inner.search(HOSTNAME_TOKEN);
    const stack = [{ tag: h5Tag, name: "h5", start: 0, end: inner.length }];
    let holder = stack[0];
    let holderFound = false;
    const others = [];

    const VOID = ["br", "img", "input", "hr", "meta", "link"];
    for (const match of inner.matchAll(/<(\/?)([a-zA-Z0-9]+)([^>]*?)(\/?)>/g)) {
        const [full, closing, name, , selfClosing] = match;
        if (closing) {
            const popped = stack.pop();
            if (!popped) continue;
            popped.end = match.index;
            // Pops run innermost-first, so the first containing element wins.
            if (!holderFound && popped.start <= hostnameAt && popped.end >= hostnameAt) {
                holder = popped;
                holderFound = true;
            }
            continue;
        }
        const element = { tag: full, name, start: match.index };
        others.push(element);
        if (!selfClosing && !VOID.includes(name)) stack.push(element);
    }
    for (const unclosed of stack) unclosed.end = inner.length;

    return { holder, others: others.filter((e) => e !== holder) };
}

function findHeaders() {
    const headers = [];
    // The inner capture must not cross another `<h5`, so a prose mention of the
    // tag cannot swallow the real template that follows it.
    for (const match of js.matchAll(/<h5([^>]*)>((?:(?!<h5)[\s\S])*?)<\/h5>/g)) {
        const [, attrs, inner] = match;
        if (!HOSTNAME_TOKEN.test(inner)) continue;
        const line = js.slice(0, match.index).split("\n").length;
        headers.push({ line, h5Tag: `<h5${attrs}>`, ...analyseHeader(`<h5${attrs}>`, inner) });
    }
    return headers;
}

const headers = findHeaders();
report(
    `${NAME}-headers-discovered`,
    headers.length > 0,
    headers.length > 0
        ? `found ${headers.length} host-card header template(s) at line(s) ${headers.map((h) => h.line).join(", ")}`
        : "no <h5> host-card header carrying the hostname was found — the sweep would pass by vacuity",
);

// --- The sweep -------------------------------------------------------------

// Selectors that could style the hostname holder, given where it sits.
function candidatesFor(holder) {
    if (holder.name === "h5") return [".host-card h5", ...classesOf(holder.tag).map((c) => `.host-card h5.${c}`)];
    return classesOf(holder.tag).flatMap((c) => [
        `.${c}`,
        `.host-card h5 .${c}`,
        `.host-card h5 > .${c}`,
        `.host-card h5 ${holder.name}.${c}`,
    ]);
}

const isFlex = (decl, tag) => (decl["display"] ?? "").trim() === "flex" || classesOf(tag).includes("d-flex");

for (const header of headers) {
    const id = `line-${header.line}`;
    const { holder } = header;
    const decl = resolved(candidatesFor(holder));
    const h5Decl = resolved([".host-card h5"]);

    const whiteSpace = (decl["white-space"] ?? "normal").trim();
    const overflow = (decl["overflow"] ?? "visible").trim();
    const textOverflow = (decl["text-overflow"] ?? "clip").trim();
    const nowrap = ["nowrap", "pre"].includes(whiteSpace);

    report(
        `${NAME}-${id}-cannot-wrap`,
        nowrap,
        `the hostname text run sits in <${holder.name} class="${classesOf(holder.tag).join(" ")}"> ` +
            `with white-space: ${whiteSpace}` +
            (nowrap ? "" : " — the text wraps onto a second line instead of overflowing, so the ellipsis never fires"),
    );

    report(
        `${NAME}-${id}-ellipsis-effective`,
        nowrap && overflow === "hidden" && textOverflow === "ellipsis",
        `hostname box: white-space: ${whiteSpace}, overflow: ${overflow}, text-overflow: ${textOverflow}` +
            (nowrap && overflow === "hidden" && textOverflow === "ellipsis"
                ? " — overflowing text is clipped with an ellipsis"
                : " — all three are needed before a long hostname truncates"),
    );

    // A flex item refuses to shrink below its content width unless its automatic
    // minimum size is neutralised, so the ellipsis would never be reached.
    const shrinkable = (decl["min-width"] ?? "").trim() === "0" || overflow === "hidden";
    report(
        `${NAME}-${id}-can-shrink`,
        shrinkable,
        `hostname box has min-width: ${decl["min-width"] ?? "auto"}, overflow: ${overflow}` +
            (shrinkable ? "" : " — it cannot shrink below its content width, so truncation never starts"),
    );

    // Truncation hides characters, and the dashboard is read on phones — the
    // full hostname has to stay discoverable.
    const title = attr(holder.tag, "title");
    report(
        `${NAME}-${id}-full-hostname-discoverable`,
        title !== null && HOSTNAME_TOKEN.test(title),
        title === null
            ? "the truncating element carries no title attribute — the hidden characters are unrecoverable"
            : `the truncating element exposes the full hostname via title="${title}"`,
    );

    // A truncating span only sits beside the machine-type / worker-silent
    // badges if the header lays its children out in a row.
    if (holder.name !== "h5") {
        report(
            `${NAME}-${id}-header-is-a-row`,
            isFlex(h5Decl, header.h5Tag),
            `header <h5 class="${classesOf(header.h5Tag).join(" ")}"> display: ${h5Decl["display"] ?? "block"}` +
                (isFlex(h5Decl, header.h5Tag)
                    ? " — the hostname box and its badges share one line"
                    : " — the badges would sit inside the text flow rather than beside the truncating box"),
        );
    }

    // The badges must be siblings of the truncating box, not inside it, or the
    // ellipsis would eat "Mac mini" / "Worker silent" before the hostname.
    const badges = header.others.filter((e) => classesOf(e.tag).includes("badge"));
    const badgeDecl = resolved([".host-card h5 .badge", ".badge"]);
    const badgesKept = badges.every((b) => b.start < holder.start || b.start > holder.end);
    report(
        `${NAME}-${id}-badges-not-clipped`,
        badges.length === 0 || (badgesKept && (badgeDecl["flex-shrink"] ?? "").trim() === "0"),
        badges.length === 0
            ? "this header carries no badges beside the hostname"
            : `${badges.length} badge(s) beside the hostname, flex-shrink: ${badgeDecl["flex-shrink"] ?? "1"}` +
                (badgesKept ? "" : " — a badge sits inside the truncating box and would be clipped away"),
    );
}
