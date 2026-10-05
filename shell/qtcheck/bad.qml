// Must fail check.py: Qt's engine has no object spread, in QML too.
import QtQml
QtObject {
    function merged(a, b) { return { ...a, ...b }; }
}
