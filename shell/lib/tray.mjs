// The tray (SPEC.md §7.4): third-party StatusNotifierItem icons, as pure
// functions the QML binds to.

// The items to show, in the order they registered. A passive item says
// it's idle and can be hidden, as waybar's tray hides it by default.
export function shownItems(items, passive) {
    return items.filter(i => i.status !== passive);
}

// What a click with `button` ("left", "middle" or "right") does to `item`
// (SPEC.md §7.4: a click opens the app's menu):
//   - "menu", its menu (DBusMenu), for a left or right click;
//   - "activate", the app's own action, usually showing its window: a
//     middle click, or a left click on an item without a menu;
//   - "secondary", its secondary action: a right click without a menu;
//   - null, nothing.
export function clickAction(button, item) {
    switch (button) {
    case "left":
        return item.hasMenu ? "menu" : "activate";
    case "middle":
        return "activate";
    case "right":
        return item.hasMenu ? "menu" : "secondary";
    default:
        return null;
    }
}

// QsMenuButtonType's values, and Qt.CheckState's Checked.
const NO_BUTTON = 0;
const CHECKED = 2;

// The rows of a tray item's menu (SPEC.md §7.4), from the QsMenuEntry list
// Quickshell reads from the app's DBusMenu, each keeping its entry for the
// click. Quickshell drops hidden entries, which can leave two separators
// together or one at either end, so separators are kept only between items.
export function menuRows(entries) {
    const rows = [];
    for (const entry of entries) {
        if (entry.isSeparator) {
            if (rows.length > 0 && !rows[rows.length - 1].separator) {
                rows.push({ separator: true });
            }
            continue;
        }
        rows.push({
            separator: false,
            entry: entry,
            label: entry.text,
            icon: entry.icon,
            enabled: entry.enabled,
            checked: entry.buttonType !== NO_BUTTON && entry.checkState === CHECKED,
            submenu: entry.hasChildren,
        });
    }
    if (rows.length > 0 && rows[rows.length - 1].separator) {
        rows.pop();
    }
    return rows;
}

// What a click on a menu row does: "open" its submenu in the menu's place,
// "trigger" its entry in the app, or null for a separator or a disabled row.
export function rowClick(row) {
    if (row.separator || !row.enabled) {
        return null;
    }
    return row.submenu ? "open" : "trigger";
}
