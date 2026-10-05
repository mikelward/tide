#!/usr/bin/env python3
"""Parse the shell's JavaScript and QML with Qt's own engine.

Quickshell runs shell/lib/*.mjs and the inline JavaScript in shell/*.qml on
Qt's engine, not Node's, and Qt rejects syntax Node accepts: object spread,
`{ ...x }`, stopped the whole shell from loading while every node test
passed. This loads each module with QJSEngine.importModule, which also
follows its imports and runs its top level, and runs each .qml file through
qmlformat, which is Qt's QML parser. PySide6 supplies both, at the Qt
version pinned in requirements.txt.

    check.py FILE...                 fail if any file doesn't parse
    check.py --expect-fail FILE...   fail if any file DOES parse
"""
import os
import subprocess
import sys

from PySide6 import __file__ as pyside_init
from PySide6.QtCore import QCoreApplication, qVersion
from PySide6.QtQml import QJSEngine

QMLFORMAT = os.path.join(os.path.dirname(pyside_init), "qmlformat")


def module_error(path):
    engine = QJSEngine()
    value = engine.importModule(os.path.abspath(path))
    if value.isError():
        return value.toString()
    if engine.hasError():
        return engine.catchError().toString()
    return None


def qml_error(path):
    # qmlformat warns about a non-UTF-8 locale on stderr; C.UTF-8 avoids it.
    env = dict(os.environ, LC_ALL="C.UTF-8")
    run = subprocess.run([QMLFORMAT, path], capture_output=True, text=True, env=env)
    if run.returncode != 0:
        return run.stderr.strip() or f"qmlformat exited {run.returncode}"
    return None


def main(argv):
    expect_fail = argv[:1] == ["--expect-fail"]
    files = argv[1:] if expect_fail else argv
    if not files:
        print("check.py: no files given", file=sys.stderr)
        return 2
    QCoreApplication([])
    bad = 0
    for path in files:
        if path.endswith(".mjs"):
            error = module_error(path)
        elif path.endswith(".qml"):
            error = qml_error(path)
        else:
            print(f"{path}: not a .mjs or .qml file", file=sys.stderr)
            return 2
        if expect_fail and error is None:
            print(f"{path}: Qt parsed a file that must fail; the check is not checking")
            bad += 1
        elif not expect_fail and error is not None:
            print(f"{path}: {error}")
            bad += 1
    verb = "rejected as expected" if expect_fail else "parsed"
    print(f"Qt {qVersion()}: {len(files) - bad} of {len(files)} files {verb}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
