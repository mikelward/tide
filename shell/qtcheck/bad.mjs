// Must fail check.py: Qt's engine has no object spread (Node does).
export const merged = (a, b) => ({ ...a, ...b });
