#!/bin/sh
#
# Tests for ci.yml's apt settings: every apt-get a job runs gives up on a
# stalled mirror and tries again, since Azure's Ubuntu mirror has held the
# test job until its limit canceled it. From the repo root:
# `sh .github/workflows/ci_test.sh`.

ci=.github/workflows/ci.yml
passed=0
failures=0

check() {
    if eval "$2"; then
        passed=$((passed + 1))
    else
        echo "FAIL $1" >&2
        failures=$((failures + 1))
    fi
}

# The lines of job $1, from its header to the next job's.
job() {
    awk -v job="  $1:" '$0 == job { on = 1; next } on && /^  [a-z][a-z-]*:$/ { exit } on' "$ci"
}

timeouts='Acquire::http::Timeout=30 Acquire::https::Timeout=30 Acquire::Retries=3'

# Each apt-get line of `test` passes every setting.
test_apt=$(job test | grep 'apt-get')
check "the test job runs apt-get" 'test -n "$test_apt"'
for setting in $timeouts; do
    missing=$(printf '%s\n' "$test_apt" | grep -v -F -- "-o $setting")
    check "every apt-get in the test job passes $setting" 'test -z "$missing"'
done

# `shell` runs apt-get as root in a container, so it writes the settings to
# apt's config first.
shell_job=$(job shell)
conf_line=$(printf '%s\n' "$shell_job" | grep -n '80-ci-timeouts' | head -n 1)
apt_line=$(printf '%s\n' "$shell_job" | grep -n 'apt-get' | head -n 1 | cut -d: -f1)
check "the shell job writes apt's timeouts" 'test -n "$conf_line"'
check "before its first apt-get" 'test -n "$conf_line" && test -n "$apt_line" && test "${conf_line%%:*}" -lt "$apt_line"'
for setting in 'Acquire::http::Timeout "30";' 'Acquire::https::Timeout "30";' 'Acquire::Retries "3";'; do
    check "the shell job's apt config says $setting" 'printf "%s\n" "$conf_line" | grep -q -F -- "$setting"'
done

# One workflow-level concurrency group: a pull request's runs share one, keyed
# by number, and a newer push cancels the stale run; a push to main is keyed by
# commit so no main run is canceled; an `edited` run queues rather than
# cancels, since GitHub doesn't promise to start runs in event order and it
# could cancel the only run on a newer head.
main_event="(github.event_name == 'push' || (github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'))"
check "ci.yml declares one workflow-level concurrency block" 'test "$(grep -c "^concurrency:$" "$ci")" -eq 1'
check "the group keys a pull request by number and main by commit" \
    'grep -qxF "  group: ci-\${{ $main_event && format('"'"'main-{0}'"'"', github.sha) || github.event.pull_request.number || github.ref }}" "$ci"'
check "a push cancels the stale run, never main or an edit" \
    'grep -qxF "  cancel-in-progress: \${{ !$main_event && github.event.action != '"'"'edited'"'"' }}" "$ci"'
check "an edit still starts a run" 'grep -qF "types: [opened, synchronize, reopened, edited]" "$ci"'

# Every job gates the merge: lanes waits for each one and passes on its
# result, so a job left out could fail without holding the pull request.
lanes_job=$(job lanes)
for name in $(awk '/^jobs:$/ { on = 1; next } on && /^  [a-z][a-z-]*:$/ { sub(/^  /, ""); sub(/:$/, ""); print }' "$ci" | grep -vx -e lanes -e classify); do
    check "lanes waits for $name" 'printf "%s\n" "$lanes_job" | grep -q "needs: \[.*\b$name\b.*\]"'
    check "and passes on its result" 'printf "%s\n" "$lanes_job" | grep -qF "$name=\${{ needs.$name.result }}"'
done

echo "ci_test.sh: $passed passed, $failures failed"
test "$failures" -eq 0
