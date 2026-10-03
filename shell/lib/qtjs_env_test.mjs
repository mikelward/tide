// Loaded before the shell/lib tests (node --import) to make Node's
// JavaScript look like the one Quickshell runs the shell in: Qt's QML
// engine implements ECMAScript 2016, plus optional chaining and `??`, and
// none of the built-ins that came later. Each one is removed here, so a
// test that reaches code calling it fails as the shell would. Syntax the
// engine rejects (object spread, `??=`, private fields) Node still
// accepts; `make test` runs qmllint over the modules for that.
//
// Three the engine also lacks stay: Node's own assert uses trimStart and
// trimEnd, and the clock tests check against Intl. No module may use them.
const removed = [
    [Array.prototype, ["flat", "flatMap", "at", "findLast", "findLastIndex", "toSorted", "toReversed", "toSpliced", "with"]],
    [String.prototype, ["matchAll", "replaceAll", "at"]],
    [Object, ["fromEntries", "hasOwn", "groupBy"]],
    [Promise, ["allSettled", "any"]],
];
for (const [target, names] of removed) {
    for (const name of names) {
        delete target[name];
    }
}
for (const name of ["structuredClone", "BigInt", "WeakRef"]) {
    delete globalThis[name];
}
