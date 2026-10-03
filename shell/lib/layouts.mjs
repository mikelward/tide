// The layout symbol after the workspaces (SPEC.md §6.1, §7.1), as pure
// functions the QML binds to. hypr/tide/layout.lua keeps each
// workspace's mode and announces it on Hyprland's event socket as
// `custom>>tide-layout>>WORKSPACE,MODE`, on each change and whenever
// the workspace becomes active. The bar can't ask for a mode, so until a
// workspace's first announcement (a shell that just started) it assumes the
// layout's default.

export const SYMBOLS = Object.freeze({
    tile: "[]=",
    threecol: "|M|",
    twocol: "||=",
    monocle: "[M]",
});

// layout.lua's default `ultrawide_aspect`: a workspace starts in threecol at
// and above this work-area aspect, and in tile below it.
export const ULTRAWIDE = 2.1;

const PREFIX = "tide-layout>>";

// The mode layout.lua gives a new workspace on a monitor `width` x `height`
// pixels at `scale`, rotated by Hyprland's `transform` (odd values turn it
// 90°), less the `reserved` logical pixels the bar takes from the top.
export function defaultMode({ width, height, scale = 1, transform = 0 }, reserved = 0) {
    const [w, h] = transform % 2 ? [height, width] : [width, height];
    const area = h / scale - reserved;
    return area > 0 && w / scale / area >= ULTRAWIDE ? "threecol" : "tile";
}

// The {workspace, mode} a custom event's data announces, or null when it's
// another custom event or names a mode this bar doesn't know.
export function parseAnnouncement(data) {
    if (typeof data !== "string" || !data.startsWith(PREFIX)) {
        return null;
    }
    const m = /^(-?\d+),([a-z]+)$/.exec(data.slice(PREFIX.length));
    if (!m || !Object.prototype.hasOwnProperty.call(SYMBOLS, m[2])) {
        return null;
    }
    return { workspace: Number(m[1]), mode: m[2] };
}

// What the bar shows for `mode` with `tiled` tiled windows on the workspace.
// Monocle shows how many windows it hides, `[n]`, and `[M]` while it hides
// none; an unknown mode shows nothing.
export function layoutSymbol(mode, tiled) {
    if (mode === "monocle" && tiled > 1) {
        return `[${tiled - 1}]`;
    }
    return SYMBOLS[mode] ?? "";
}
