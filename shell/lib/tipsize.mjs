// When a hover popup in the bar shows (BarTip.qml, WindowTitle.qml).
// Quickshell doesn't resize a popup that's already showing: it places it
// again at the size it had. So a popup that showed as its text came in,
// before its width had followed, stayed a sliver of its text's middle.
// It shows once its size is worked out for the text it shows: `sizedFor`
// is that text, set a turn of the event loop after `text` changes, when
// the size's bindings have run. A change while it shows hides it for that
// turn, and it comes back at the new size.
export function tipShown(text, sizedFor) {
    return typeof text === "string" && text !== "" && text === sizedFor;
}
