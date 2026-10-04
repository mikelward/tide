// The palette (SPEC.md §15): theme/palette.json, dark and light, in the
// mocks' token names. This turns it into what each consumer reads. So far
// that is the shell's shell/lib/palette.mjs; GTK, Qt and Hyprland's come
// with M7.

const HEX = /^#[0-9a-f]{6}$/;
const RGBA = /^rgba\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(0|1|0?\.\d+|1\.0+)\s*\)$/;

function hex2(n) {
    return n.toString(16).padStart(2, "0");
}

// A color as QML reads one: "#rrggbb", or "#aarrggbb" when translucent.
// Throws, naming the color, on anything else.
export function qmlColor(name, value) {
    if (typeof value === "string" && HEX.test(value)) {
        return value;
    }
    const m = typeof value === "string" ? RGBA.exec(value) : null;
    const rgb = m ? [m[1], m[2], m[3]].map(Number) : [];
    if (!m || rgb.some(c => c > 255)) {
        throw new Error(`${name}: ${JSON.stringify(value)} is not "#rrggbb" or "rgba(r, g, b, a)"`);
    }
    const alpha = Math.round(Number(m[4]) * 255);
    return `#${hex2(alpha)}${rgb.map(hex2).join("")}`;
}

// "surface-2" -> "surface2", "fg-dim" -> "fgDim".
export function camel(name) {
    return name.replace(/-([a-z0-9])/g, (_, c) => /\d/.test(c) ? c : c.toUpperCase());
}

// The palette's two modes, checked: both present, the same names in each,
// and every color readable. Throws with every problem found.
export function checked(palette) {
    const errors = [];
    for (const mode of ["dark", "light"]) {
        if (typeof palette?.[mode] !== "object" || palette[mode] === null || Array.isArray(palette[mode])) {
            errors.push(`no "${mode}" palette`);
        }
    }
    if (errors.length > 0) {
        throw new Error(errors.join("\n"));
    }
    for (const mode of Object.keys(palette)) {
        if (mode !== "dark" && mode !== "light") {
            errors.push(`"${mode}": not "dark" or "light"`);
        }
    }
    const names = new Set([...Object.keys(palette.dark), ...Object.keys(palette.light)]);
    const out = { dark: {}, light: {} };
    // QML's name for each token, so two tokens that would share one (like
    // "surface-2" and "surface2") are an error rather than one silently
    // replacing the other.
    const qmlNames = new Map();
    for (const name of [...names].sort()) {
        if (!/^[a-z][a-z0-9]*(-[a-z0-9]+)*$/.test(name)) {
            errors.push(`"${name}": names are lowercase words joined by "-"`);
            continue;
        }
        const qml = camel(name);
        if (qmlNames.has(qml)) {
            errors.push(`"${name}" and "${qmlNames.get(qml)}": both are ${qml} in QML`);
            continue;
        }
        qmlNames.set(qml, name);
        for (const mode of ["dark", "light"]) {
            if (!(name in palette[mode])) {
                errors.push(`${mode}.${name}: missing; it's in the other mode`);
                continue;
            }
            try {
                out[mode][qml] = qmlColor(`${mode}.${name}`, palette[mode][name]);
            } catch (e) {
                errors.push(e.message);
            }
        }
    }
    if (errors.length > 0) {
        throw new Error(errors.join("\n"));
    }
    return out;
}

// shell/lib/palette.mjs's text.
export function shellModule(palette) {
    const p = checked(palette);
    const block = mode => Object.entries(p[mode]).map(([k, v]) => `        ${k}: "${v}",`).join("\n");
    return `// Generated from theme/palette.json by \`make palette\`; don't edit.
// Theme.qml reads it (SPEC.md §15).

export const PALETTE = {
    dark: {
${block("dark")}
    },
    light: {
${block("light")}
    },
};
`;
}

// The custom properties a mock stylesheet sets in one block
// (".theme-dark { ... }"), by name, as written.
export function cssTokens(css, selector) {
    const start = css.indexOf(`${selector} {`);
    if (start < 0) {
        throw new Error(`no "${selector}" block`);
    }
    const body = css.slice(start, css.indexOf("}", start));
    const tokens = {};
    for (const m of body.matchAll(/--([a-z0-9-]+):\s*([^;]+);/g)) {
        tokens[m[1]] = m[2].trim();
    }
    return tokens;
}
