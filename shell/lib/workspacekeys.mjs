// The workspace keys the shell does for a compositor that can't (SPEC.md
// §6.6): Super+1…9 and Super+0, Super+Home, Super+Tab and Super+End, as
// pure functions. conf's tidewm config runs `qs -c tide ipc call
// workspaces …` for them (WorkspaceKeys.qml); conf's hyprland.lua does the
// same in Lua, which these follow.

import { sameName } from "./workspacenames.mjs";
import { workspaceOf } from "./span.mjs";

// The workspaces other than home, the one used last first.
export const NO_HISTORY = Object.freeze([]);
// The most it keeps, as hyprland.lua does.
export const HISTORY_SIZE = 50;

// The history once workspace `name` is the current one: it moves to the
// front. Home, a special workspace and none ("") aren't kept, and a
// monitor's part of a spanning workspace (span.mjs) counts as the
// workspace.
export function used(history, name, home) {
    const n = workspaceOf(name ?? "");
    if (n === "" || n.startsWith("special:") || n === home) {
        return history;
    }
    if (history[0] === n) {
        return history;
    }
    return [n].concat(history.filter((h) => h !== n)).slice(0, HISTORY_SIZE);
}

// The workspace used last other than home and `except`, still there: a
// standing one, made or not, or one listed (`names`, plain names). Home is
// left out here as well as in used(): a change of home can name a
// workspace already in the history home. null with none.
export function lastUsed(history, { except = null, home, standing = [], names = [] }) {
    const there = (n) => names.includes(n) || standing.some((s) => sameName(s, n));
    return history.find((n) => n !== except && n !== home && there(n)) ?? null;
}

// Super+N's workspace: the Nth name in the bar's order (`order`, from
// workspaces.mjs's workspaceOrder), or the last for 0; null past the end,
// or for anything but 0…9.
export function nth(order, n) {
    if (!Number.isInteger(n) || n < 0 || n > 9) {
        return null;
    }
    return order[n === 0 ? order.length - 1 : n - 1]?.name ?? null;
}

// Super+Tab's workspace: home from any other, and from home the last other
// one used (lastUsed), so presses toggle. null means stay.
export function homeOrBack(here, history, place) {
    return here !== place.home ? place.home : lastUsed(history, place);
}

// Super+End's workspace: the last used other than home and this one, so
// presses toggle between two and never reach home. null means stay.
export function lastOther(here, history, place) {
    return lastUsed(history, Object.assign({}, place, { except: here }));
}
