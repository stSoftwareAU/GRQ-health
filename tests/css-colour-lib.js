// Shared CSS-parsing and WCAG colour helpers for the dark-mode checkers.
//
// Extracted from tests/dark-mode-table-check.js (Issues #165/#170/#171) so the
// generalised host-card sweep in tests/dark-mode-card-check.js (Issue #172) can
// reuse the same parsing and colour maths rather than duplicating it.

// --- Minimal CSS helpers ---------------------------------------------------

// Comments must go first — otherwise they get swept into the selector capture.
export function stripComments(css) {
    return css.replace(/\/\*[\s\S]*?\*\//g, "");
}

// Every `selectors { body }` pair in the stylesheet, selectors whitespace-normalised.
export function* rules(css) {
    for (const match of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
        yield {
            selectors: match[1].split(",").map((s) => s.trim().replace(/\s+/g, " ")),
            body: match[2],
        };
    }
}

// Return the declaration block for an exact selector, or null when absent.
export function ruleBody(css, selector) {
    for (const rule of rules(css)) {
        if (rule.selectors.includes(selector)) return rule.body;
    }
    return null;
}

export function declarations(body) {
    const out = {};
    for (const decl of (body ?? "").split(";")) {
        const idx = decl.indexOf(":");
        if (idx === -1) continue;
        out[decl.slice(0, idx).trim()] = decl.slice(idx + 1).trim()
            .replace(/\s*!important\s*$/, "");
    }
    return out;
}

// Resolve `var(--x)` references against a palette, one hop at a time, so rules
// may reuse the existing custom properties instead of colour literals.
export function makeResolver(palette) {
    return function resolveValue(value, depth = 0) {
        if (!value || depth > 5) return value;
        const varMatch = value.match(/^var\(\s*(--[\w-]+)\s*(?:,\s*([^)]*))?\)$/);
        if (!varMatch) return value;
        const referenced = palette[varMatch[1]] ?? varMatch[2];
        return resolveValue(referenced?.trim(), depth + 1);
    };
}

// Split a `background` shorthand into its top-level layers, keeping the commas
// inside `linear-gradient(...)` with their gradient. Layers are listed
// top-most first, as CSS paints them.
export function splitLayers(value) {
    const layers = [];
    let depth = 0;
    let current = "";
    for (const ch of value ?? "") {
        if (ch === "(") depth++;
        else if (ch === ")") depth--;
        if (ch === "," && depth === 0) {
            layers.push(current.trim());
            current = "";
        } else {
            current += ch;
        }
    }
    if (current.trim()) layers.push(current.trim());
    return layers;
}

// --- Colour maths (WCAG 2.1 relative luminance and contrast) ---------------

export function parseColour(value) {
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
export function flatten(colour, backdrop) {
    if (colour.a >= 1) return colour;
    return {
        r: colour.r * colour.a + backdrop.r * (1 - colour.a),
        g: colour.g * colour.a + backdrop.g * (1 - colour.a),
        b: colour.b * colour.a + backdrop.b * (1 - colour.a),
        a: 1,
    };
}

export function luminance(colour) {
    const channel = (c) => {
        const s = c / 255;
        return s <= 0.03928 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * channel(colour.r) + 0.7152 * channel(colour.g) + 0.0722 * channel(colour.b);
}

export function contrast(a, b) {
    const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
}

// Largest per-channel difference between two opaque colours.
export function channelDelta(a, b) {
    return Math.max(Math.abs(a.r - b.r), Math.abs(a.g - b.g), Math.abs(a.b - b.b));
}

export function report(name, ok, detail) {
    console.log(`TEST_RESULT:${name}:${ok ? "PASS" : "FAIL"}:${detail}`);
}
