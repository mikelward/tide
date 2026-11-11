// The settings page a right-click on each bar item opens (SPEC.md §7.1):
// a page's id in settings.mjs's PAGES, "bar" (the Bar page) where no
// other page fits, or "" for the panel's first page. `bar` is the bar
// itself, a right-click anywhere that isn't an item. The tray isn't here:
// its right-click is the app's own menu. tide for macOS copies this file
// as its dashboard/tide-barsettings.js.
export const BAR_SETTINGS = Object.freeze({
    bar: "bar",
    logo: "bar",
    workspaces: "workspaces",
    layout: "layouts",
    title: "floating",
    presenter: "notifications",
    sharing: "bar",
    mic: "sound",
    keyboard: "keyboard",
    keepawake: "idle",
    bluetooth: "bluetooth",
    network: "network",
    volume: "sound",
    battery: "power",
    sysmon: "bar",
    notifications: "notifications",
    session: "idle",
    clocks: "clocks",
});

// The page bar item `item` opens. An item not in the map is a mistake in
// the bar, so it throws rather than open the wrong page.
export function page(item) {
    if (!Object.prototype.hasOwnProperty.call(BAR_SETTINGS, item)) {
        throw new Error(`no bar item ${item}; the items are ${Object.keys(BAR_SETTINGS).join(", ")}`);
    }
    return BAR_SETTINGS[item];
}

// The page to open for `id`, one of the map's: "" names the first of
// `pages` (settings.mjs's PAGES), so a panel open on another turns to it.
export function opened(id, pages) {
    return id || pages[0].id;
}
