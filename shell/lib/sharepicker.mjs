// The screen-share picker's logic (SPEC.md §12), as pure functions the QML
// binds to: xdph's window list, the options and their order, the choice it
// opens on, and the line `tide-share-picker` prints for xdph.

// xdph 1.4.1 hands the picker its windows in XDPH_WINDOW_SHARING_LIST:
// `<id>[HC>]<class>[HT>]<title>[HE>]<address>[HA>]` for each, where the id
// is what a `window:` answer names and the address is Hyprland's, in
// decimal. xdph has already blanked quotes, `$` and backquotes, and the
// `]` of a `>]` inside a name, so the separators can't appear in one.
export function parseWindows(list) {
    const windows = [];
    for (const entry of String(list ?? "").split("[HA>]")) {
        const hc = entry.indexOf("[HC>]");
        const ht = entry.indexOf("[HT>]", hc + 5);
        const he = entry.indexOf("[HE>]", ht + 5);
        if (hc < 0 || ht < 0 || he < 0) {
            continue;
        }
        const id = entry.slice(0, hc).trim();
        if (!/^[0-9]+$/.test(id)) {
            continue;
        }
        windows.push({
            id: id,
            cls: entry.slice(hc + 5, ht),
            title: entry.slice(ht + 5, he),
            address: decimalToHex(entry.slice(he + 5).trim())
        });
    }
    return windows;
}

// A decimal string as lowercase hex with no leading zeros, the form
// workspaces.mjs's normalizeAddress gives Hyprland's addresses, or null for
// 0 (xdph's "no Hyprland window") or anything not a number. By long
// division, since Quickshell's JavaScript has no BigInt and an address is
// past what a double holds exactly.
export function decimalToHex(text) {
    if (!/^[0-9]+$/.test(String(text ?? ""))) {
        return null;
    }
    let digits = String(text).split("").map(Number);
    let hex = "";
    while (digits.length > 0 && !(digits.length === 1 && digits[0] === 0)) {
        const quotient = [];
        let rest = 0;
        for (const d of digits) {
            const n = rest * 10 + d;
            const q = Math.floor(n / 16);
            rest = n % 16;
            if (quotient.length > 0 || q > 0) {
                quotient.push(q);
            }
        }
        hex = "0123456789abcdef"[rest] + hex;
        digits = quotient;
    }
    return hex === "" ? null : hex;
}

// A monitor counts as an ultrawide from 2:1, which takes in 21:9 and 32:9
// and leaves out 16:9 and 16:10.
export function isUltrawide(screen) {
    return !!screen && screen.height > 0 && screen.width >= 2 * screen.height;
}

// The 16:9 slice in the middle of a monitor wider than 16:9, in its logical
// pixels, which is what xdph's `region:` takes. For 3440×1440 at scale 1,
// x 440, width 2560. A monitor no wider than 16:9 has none.
export function areaFor(screen) {
    if (!screen || !(screen.height > 0) || screen.width * 9 <= screen.height * 16) {
        return null;
    }
    const w = Math.round(screen.height * 16 / 9);
    return {
        output: screen.name,
        x: Math.floor((screen.width - w) / 2),
        y: 0,
        w: w,
        h: screen.height
    };
}

// The windows in the dialog's order: the current workspace's first, then by
// workspace number, keeping xdph's order within one. A window Hyprland
// doesn't place (`workspaceOf` gives null) goes last.
export function orderWindows(windows, workspaceOf, current) {
    const rank = w => {
        const ws = workspaceOf(w.address);
        if (ws === null || ws === undefined) {
            return Infinity;
        }
        return ws === current ? -Infinity : ws;
    };
    return windows
        .map((w, i) => ({ w: w, i: i, r: rank(w) }))
        .sort((a, b) => (a.r === b.r ? a.i - b.i : (a.r < b.r ? -1 : 1)))
        .map(e => e.w);
}

// Every option, in the order the arrow keys move through them: screens,
// windows, then areas. Each has the key a remembered choice is matched by
// and the selection xdph reads.
export function options(screens, windows, workspaceOf, current) {
    const all = [];
    for (const s of screens) {
        all.push({ kind: "screen", key: `screen:${s.name}`, screen: s.name, label: s.name, detail: `${s.width}×${s.height}` });
    }
    for (const w of orderWindows(windows, workspaceOf, current)) {
        const ws = workspaceOf(w.address);
        all.push({
            kind: "window",
            key: `window:${w.id}`,
            address: w.address,
            label: w.title || w.cls,
            detail: ws === null || ws === undefined ? "" : String(ws),
            cls: w.cls
        });
    }
    for (const s of screens) {
        const a = areaFor(s);
        if (a) {
            all.push({
                kind: "region",
                key: `region:${a.output}@${a.x},${a.y},${a.w},${a.h}`,
                screen: a.output,
                area: a,
                label: `16:9 in the middle of ${a.output}`,
                detail: `${a.w}×${a.h}`
            });
        }
    }
    return all;
}

// How long a choice is offered again: Chrome opens two to four portal
// sessions for one share (§12).
export const REPEAT_MS = 10000;

// The option the dialog opens on, as an index into `opts`:
// - the last choice, if it was made within REPEAT_MS and is still offered;
// - on an ultrawide, the focused window, since a whole one arrives
//   letterboxed and unreadable;
// - otherwise the focused monitor;
// - otherwise the first option.
export function preselect(opts, focus, last, now) {
    const at = key => opts.findIndex(o => o.key === key);
    if (last && now - last.time >= 0 && now - last.time <= REPEAT_MS) {
        const i = at(last.key);
        if (i >= 0) {
            return i;
        }
    }
    const screen = focus.screen;
    if (isUltrawide(screen) && focus.address) {
        const i = opts.findIndex(o => o.kind === "window" && o.address === focus.address);
        if (i >= 0) {
            return i;
        }
    }
    if (screen) {
        const i = at(`screen:${screen.name}`);
        if (i >= 0) {
            return i;
        }
    }
    return opts.length > 0 ? 0 : -1;
}

// The line xdph reads (`promptForScreencopySelection` in its
// ScreencopyShared.cpp): `[SELECTION]`, the flags (`r` grants a restore
// token), `/`, then the choice. xdph drops a `screen:` answer's last
// character, so the newline that ends it matters.
export function selectionLine(option, reuse) {
    return `[SELECTION]${reuse ? "r" : ""}/${option.key}`;
}

// The command that writes `line` to the picker's pipe at `reply`. dd's
// nocreat opens the path or fails: a pipe the picker has removed, at any
// moment before the write, fails it rather than leaving a file that reads
// as delivered. A pipe nobody reads blocks the open, so it's bounded.
export function answerCommand(line, reply) {
    return ["timeout", "5", "sh", "-c", 'printf "%s\\n" "$1" | dd of="$2" conv=nocreat status=none', "sh", line, reply];
}

// What the shell does once that write ends, with `code` its exit status
// and `kind` what the answer shares ("" for no): the kind to tell
// ShareData, only once the picker has the answer, since a choice that never
// reached xdph has no stream to pair with (§12); and a warning for a write
// that failed, a picker that stopped waiting among them.
export function answerOutcome(code, kind) {
    if (code === 0) {
        return { chose: kind || null, warning: null };
    }
    return { chose: null, warning: `answering tide-share-picker failed (exit ${code}), so it went nowhere` };
}

// The share button's label for the highlighted option.
export function shareLabel(option) {
    if (!option) {
        return "Share";
    }
    return { screen: "Share screen", window: "Share window", region: "Share area" }[option.kind] ?? "Share";
}

// Whether `path` is a reply pipe `tide-share-picker` made, named as it
// names them in the runtime directory, so the shell writes nowhere else.
export function validReply(path, runtimeDir) {
    if (!runtimeDir) {
        return false;
    }
    const prefix = `${runtimeDir.replace(/\/+$/, "")}/tide-share-picker.`;
    const p = String(path ?? "");
    return p.startsWith(prefix) && /^[A-Za-z0-9]+$/.test(p.slice(prefix.length));
}

// Where a list of options, `viewHeight` tall over `contentHeight` of them
// and scrolled to `y`, scrolls to show one from `top` down `height`, with
// `margin` around it: as little as it can, its top first if it's taller
// than the view, and never past either end.
export function revealY(y, viewHeight, contentHeight, top, height, margin) {
    let to = y;
    if (top + height + margin > to + viewHeight) {
        to = top + height + margin - viewHeight;
    }
    if (top - margin < to) {
        to = top - margin;
    }
    return Math.max(0, Math.min(to, contentHeight - viewHeight));
}
