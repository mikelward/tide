#!/bin/sh
#
# Tests for shell/shell_test.sh itself, with stand-ins for qs and sway, so
# they run without Quickshell: what the load test does with a shell that
# loads cleanly, one whose files report an error, and one whose event loop
# never answers.

cd "$(dirname "$0")/.." || exit 1

passes=0
failures=0
pass() { passes=$((passes + 1)); }
fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1" >&2
}
check() {
    _name=$1
    shift
    if "$@"; then pass; else fail "$_name"; fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# The stand-in sway has to make a real Wayland socket for the test to find.
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: shell/shell_test_test.sh: no python3 for the stand-in sway"
    exit 0
fi

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

# stubs DIR IPC LOAD: a sway that listens on wayland-1 until it's killed,
# and a qs whose `ipc` runs IPC and whose load prints LOAD then waits.
stubs() {
    mkdir -p "$1" || exit 1
    cat >"$1/sway" <<'EOF'
#!/bin/sh
exec python3 -c 'import os, socket, time
s = socket.socket(socket.AF_UNIX)
s.bind(os.environ["XDG_RUNTIME_DIR"] + "/wayland-1")
time.sleep(3600)'
EOF
    cat >"$1/qs" <<EOF
#!/bin/sh
if test "\$1" = ipc; then
    $2
fi
printf '%s\n' '$3'
exec sleep 3600
EOF
    chmod +x "$1/sway" "$1/qs" || exit 1
}

# run DIR [VAR=VALUE...]: the load test with DIR's stand-ins, a 2 s limit,
# Quickshell required, so a missing stand-in fails instead of skipping, and
# any settings given. Sets $out, $code and $took (seconds).
run() {
    _dir=$1
    shift
    _start=$(date +%s)
    out=$(env PATH="$_dir:$PATH" TIDE_REQUIRE_QS=1 TIDE_LOAD_WAIT=2 "$@" sh shell/shell_test.sh 2>&1)
    code=$?
    took=$(($(date +%s) - _start))
}

stubs "$tmp/clean" "exit 0" "  INFO: Configuration Loaded"
run "$tmp/clean"
check "a shell that loads and answers passes" test "$code" -eq 0
check "and says both loaded" contains "$out" "ok: Quickshell loads the lock"

run "$tmp/clean" TIDE_KEEP_LOG="$tmp/kept.log"
check "a log asked for is kept" test "$code" -eq 0
check "with Quickshell's lines in it" grep -q 'Configuration Loaded' "$tmp/kept.log"

run "$tmp/clean" TIDE_KEEP_LOG="$tmp/no-such-dir/kept.log"
check "a log that can't be kept fails a run that passed" test "$code" -ne 0
check "and says so" contains "$out" "couldn't keep the logs in $tmp/no-such-dir/kept.log"

stubs "$tmp/reports" "exit 0" "  WARN scene: @Bar.qml[31:-1]: ReferenceError: x is not defined
  INFO: Configuration Loaded"
run "$tmp/reports"
check "a shell whose file reports an error fails" test "$code" -ne 0
check "and names the report" contains "$out" "@Bar.qml[31:-1]: ReferenceError"

stubs "$tmp/stuck" "exec sleep 3600" "  INFO: Configuration Loaded"
run "$tmp/stuck"
check "a shell that loads but never answers IPC fails" test "$code" -ne 0
check "and says so" contains "$out" "didn't answer IPC within 2 s"
check "within the limit, not hanging ($took s)" test "$took" -lt 30

stubs "$tmp/broken" "exit 0" " ERROR: Failed to load configuration"
run "$tmp/broken"
check "a shell that fails to load fails" test "$code" -ne 0
check "and shows Quickshell's log" contains "$out" "Failed to load configuration"

printf 'shell_test_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
