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

echo "ci_test.sh: $passed passed, $failures failed"
test "$failures" -eq 0
