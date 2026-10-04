#!/bin/sh
#
# Tests for bin/tide-sysmon, over a fake /proc and /sys tree.

cd "$(dirname "$0")/.." || exit 1
sysmon=$PWD/bin/tide-sysmon

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

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
tab=$(printf '\t')

# A machine with Intel's throttle counter, cpufreq on two CPUs, a coretemp
# package sensor with limits and an ACPI zone with none, and two processes.
r=$tmp/full
mkdir -p "$r/proc/1" "$r/proc/42" "$r/proc/self" \
    "$r/sys/devices/system/cpu/cpu0/cpufreq" "$r/sys/devices/system/cpu/cpu1/cpufreq" \
    "$r/sys/devices/system/cpu/cpu0/thermal_throttle" \
    "$r/sys/class/hwmon/hwmon0" "$r/sys/class/hwmon/hwmon1"
printf 'cpu  1 2 3 4 5 6 7 8 0 0\ncpu0 1 2 3 4 5 6 7 8 0 0\n' > "$r/proc/stat"
echo '1 (systemd) S 0' > "$r/proc/1/stat"
echo '42 (Web Content) R 1' > "$r/proc/42/stat"
echo 'not a pid' > "$r/proc/self/stat"
echo 4700000 > "$r/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
# cpu1 is the faster core, as on a big.LITTLE or P/E machine.
echo 5200000 > "$r/sys/devices/system/cpu/cpu1/cpufreq/cpuinfo_max_freq"
echo 800000 > "$r/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
echo 3100000 > "$r/sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq"
echo 7 > "$r/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count"
echo coretemp > "$r/sys/class/hwmon/hwmon0/name"
echo 61000 > "$r/sys/class/hwmon/hwmon0/temp1_input"
echo 'Package id 0' > "$r/sys/class/hwmon/hwmon0/temp1_label"
echo 100000 > "$r/sys/class/hwmon/hwmon0/temp1_max"
echo 105000 > "$r/sys/class/hwmon/hwmon0/temp1_crit"
echo acpitz > "$r/sys/class/hwmon/hwmon1/name"
echo 50000 > "$r/sys/class/hwmon/hwmon1/temp1_input"

out=$(TIDE_SYSMON_ROOT=$r "$sysmon" probe); code=$?
check "probe exits 0" test "$code" -eq 0
check "probe gives the page size" contains "$out" "page$tab"
check "probe gives the fastest CPU's top frequency" contains "$out" "maxfreq${tab}5200000"
check "probe gives the throttle counter's real path" \
    contains "$out" "throttle$tab/sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count"
check "probe lists a sensor with its limits" \
    contains "$out" "temp$tab/sys/class/hwmon/hwmon0/temp1_input${tab}coretemp${tab}Package id 0${tab}100000${tab}105000"
check "probe lists a sensor with no label or limits" \
    contains "$out" "temp$tab/sys/class/hwmon/hwmon1/temp1_input${tab}acpitz$tab$tab$tab"
check "a probe that read everything is complete" test "$(printf '%s\n' "$out" | grep -c '^incomplete$')" -eq 0

out=$(TIDE_SYSMON_ROOT=$r "$sysmon" sample); code=$?
check "sample exits 0" test "$code" -eq 0
expected=$(printf '@stat\ncpu  1 2 3 4 5 6 7 8 0 0\ncpu0 1 2 3 4 5 6 7 8 0 0\n@freq\n800000\n3100000\n@procs\n1 (systemd) S 0\n42 (Web Content) R 1')
check "sample gives stat, frequencies and numeric pids only" test "$out" = "$expected"

# A process can put a newline in its own name; its record stays one line.
mkdir -p "$r/proc/77"
printf '77 (two\nlines) S 1\n' > "$r/proc/77/stat"
out=$(TIDE_SYSMON_ROOT=$r "$sysmon" sample)
check "a name with a newline stays on one line" contains "$out" "77 (two lines) S 1"
rm -r "$r/proc/77"

# A VM: no cpufreq, no throttle counter, no sensors.
v=$tmp/vm
mkdir -p "$v/proc/1" "$v/sys/devices/system/cpu/cpu0" "$v/sys/class/hwmon"
printf 'cpu  1 2 3 4\n' > "$v/proc/stat"
echo '1 (init) S 0' > "$v/proc/1/stat"
out=$(TIDE_SYSMON_ROOT=$v "$sysmon" probe 2>&1); code=$?
check "a bare probe exits 0" test "$code" -eq 0
check "a bare probe has no throttle, frequency or sensors, and is complete" test "$(printf '%s\n' "$out" | grep -c -v '^page')" -eq 0
out=$(TIDE_SYSMON_ROOT=$v "$sysmon" sample 2>&1); code=$?
check "a bare sample exits 0" test "$code" -eq 0
check "a bare sample has an empty @freq" contains "$out" "@freq
@procs"

# A sensor file that's there but can't be read is reported, not taken
# for missing; the sensor is still listed.
b=$tmp/broken
mkdir -p "$b/proc" "$b/sys/devices/system/cpu/cpu0" "$b/sys/class/hwmon/hwmon0/name"
echo 40000 > "$b/sys/class/hwmon/hwmon0/temp1_input"
out=$(TIDE_SYSMON_ROOT=$b "$sysmon" probe 2>"$tmp/err"); code=$?
check "an unreadable name still probes" test "$code" -eq 0
check "and still lists the sensor" contains "$out" "temp$tab/sys/class/hwmon/hwmon0/temp1_input"
check "and says which file it couldn't read" contains "$(cat "$tmp/err")" "can't read /sys/class/hwmon/hwmon0/name"
check "and marks the probe incomplete" contains "$out" "incomplete"
check "a missing label or limit says nothing" test "$(grep -c "temp1_label\|temp1_max\|temp1_crit" "$tmp/err")" -eq 0

# A file that's there but can't be read is reported, where a missing one
# isn't. Root reads anything, so this runs as nobody when it can.
if test "$(id -u)" -ne 0; then
    as_other=
elif command -v setpriv >/dev/null 2>&1; then
    as_other="setpriv --reuid=65534 --regid=65534 --clear-groups"
else
    as_other=skip
fi
if test "$as_other" = skip; then
    echo "tide-sysmon_test.sh: running as root without setpriv; unreadable-file cases not run" >&2
else
    u=$tmp/unreadable
    mkdir -p "$u/proc" "$u/sys/devices/system/cpu/cpu0/cpufreq" \
        "$u/sys/devices/system/cpu/cpu0/thermal_throttle" "$u/sys/class/hwmon/hwmon0"
    printf 'cpu  1 2 3 4\n' > "$u/proc/stat"
    echo coretemp > "$u/sys/class/hwmon/hwmon0/name"
    unreadable="sys/class/hwmon/hwmon0/temp1_input sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq
        sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
        sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count"
    unreadable="$unreadable proc/7/stat"
    mkdir -p "$u/proc/7" "$u/proc/8"
    echo '8 (ok) S 1' > "$u/proc/8/stat"
    for f in $unreadable; do
        echo 1 > "$u/$f"
    done
    # nobody has to reach the tree mktemp made private, but not these files.
    chmod -R a+rX "$tmp" || fail "chmod $tmp"
    for f in $unreadable; do
        chmod 000 "$u/$f"
    done
    out=$(TIDE_SYSMON_ROOT=$u $as_other "$sysmon" probe 2>"$tmp/err"); code=$?
    check "an unreadable sensor still probes" test "$code" -eq 0
    check "and lists no reading it couldn't take" test "$(printf '%s\n' "$out" | grep -c -v '^page\|^incomplete$')" -eq 0
    check "and marks the probe incomplete" contains "$out" "incomplete"
    err=$(cat "$tmp/err")
    check "an unreadable temperature input is reported" contains "$err" "can't read /sys/class/hwmon/hwmon0/temp1_input"
    check "an unreadable max frequency is reported" contains "$err" "can't read /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
    check "an unreadable throttle counter is reported" \
        contains "$err" "can't read /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_count"
    TIDE_SYSMON_ROOT=$u $as_other "$sysmon" sample > "$tmp/out" 2>"$tmp/err"
    check "an unreadable current frequency is reported" \
        contains "$(cat "$tmp/err")" "can't read /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"
    check "an unreadable process is reported" contains "$(cat "$tmp/err")" "can't read /proc/7/stat"
    check "a readable process is still listed" contains "$(cat "$tmp/out")" "8 (ok) S 1"
    check "and the unreadable one isn't" test "$(grep -c '^7 ' "$tmp/out")" -eq 0
fi

# A read that fails after the file opened (an I/O error, here a directory
# where a file should be) is reported too, not taken for an empty value.
d=$tmp/ioerror
mkdir -p "$d/proc/9/stat" "$d/proc/8" "$d/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
printf 'cpu  1 2 3 4\n' > "$d/proc/stat"
echo '8 (ok) S 1' > "$d/proc/8/stat"
out=$(TIDE_SYSMON_ROOT=$d "$sysmon" probe 2>"$tmp/err"); code=$?
check "a failed max-frequency read still probes" test "$code" -eq 0
check "and gives no empty maxfreq line" test "$(printf '%s\n' "$out" | grep -c '^maxfreq')" -eq 0
check "and marks the probe incomplete" contains "$out" "incomplete"
check "and says which file" contains "$(cat "$tmp/err")" "can't read /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"
TIDE_SYSMON_ROOT=$d "$sysmon" sample > "$tmp/out" 2>"$tmp/err"
check "a failed process read is reported" contains "$(cat "$tmp/err")" "can't read /proc/9/stat"
check "and prints no blank record" test "$(sed -n '/^@procs$/,$p' "$tmp/out" | grep -c '^$')" -eq 0
check "and the readable process is still listed" contains "$(cat "$tmp/out")" "8 (ok) S 1"

# Without /proc/stat there's nothing to sample.
e=$tmp/empty
mkdir -p "$e/proc"
TIDE_SYSMON_ROOT=$e "$sysmon" sample > /dev/null 2>"$tmp/err"; code=$?
check "a missing /proc/stat fails" test "$code" -eq 1
check "and says which file" contains "$(cat "$tmp/err")" "proc/stat"

# Without a page size there's no process memory to give, so the probe
# fails, saying why, rather than leaving the shell to guess one.
fakebin=$tmp/fakebin
mkdir -p "$fakebin"
printf '#!/bin/sh\necho "getconf: broken" >&2\nexit 1\n' > "$fakebin/getconf"
chmod +x "$fakebin/getconf"
out=$(PATH=$fakebin:$PATH TIDE_SYSMON_ROOT=$r "$sysmon" probe 2>"$tmp/err"); code=$?
check "a failed getconf fails the probe" test "$code" -eq 1
check "and says so" contains "$(cat "$tmp/err")" "getconf PAGESIZE failed"
check "and gives no page line" test "$(printf '%s\n' "$out" | grep -c '^page')" -eq 0

"$sysmon" bogus 2>/dev/null; code=$?
check "an unknown command is a usage error" test "$code" -eq 2

printf 'tide-sysmon_test.sh: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
