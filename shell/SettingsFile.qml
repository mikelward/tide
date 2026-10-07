import QtQuick
import Quickshell.Io

// A settings file read and written as it's needed, synchronously (SPEC.md
// §16.1): the shell reads it just before each change and writes it at once,
// so a change builds on the one before it and on a hand edit made a moment
// earlier, with no read or write in flight for another change to race.
FileView {
    id: file

    // Why it can't be read, or "" when it can (or doesn't exist).
    property string broken: ""
    // Why the last write failed, or "".
    property string failure: ""

    // The file's text now, or null when it doesn't exist or can't be read
    // (which sets `broken`). blockAllReads makes text() read it before
    // returning, so loaded or loadFailed has fired by then.
    function readNow() {
        file.reload();
        const text = file.text();
        return file.loaded && file.broken === "" ? text : null;
    }

    // Writes the file now, returning why it couldn't, or "". blockWrites
    // makes setText() write before returning, so saved or saveFailed has
    // fired by then. A failed write leaves FileView holding the text it
    // couldn't write, which the next readNow replaces with the file's.
    function writeNow(text) {
        file.failure = "";
        file.setText(text);
        if (file.failure !== "") {
            return file.failure;
        }
        // An atomic write whose commit fails is only logged, and still
        // signals saved (Quickshell 0.3.1), so read it back.
        if (file.readNow() !== text) {
            return file.broken !== "" ? file.broken : `${file.path}: the write didn't take`;
        }
        return "";
    }

    preload: false
    blockAllReads: true
    blockWrites: true
    atomicWrites: true
    printErrors: false
    onLoaded: broken = ""
    onLoadFailed: error => {
        // A missing file is nothing set, not an error.
        broken = error === FileViewError.FileNotFound ? "" : `${path}: ${FileViewError.toString(error)}`;
        if (broken !== "") {
            console.warn(`tide: ${broken}`);
        }
    }
    onSaveFailed: error => failure = `${path}: ${FileViewError.toString(error)}`
}
