#!/bin/sh
# Tests for tide's boot splash theme (plymouth/tide), as Plymouth's two-step
# plugin and the distros' initramfs hooks read it. Plymouth can't run here,
# so this checks what they read: the theme file's keys, and that each image
# they load is there, a PNG, and the size the layout was drawn for.

cd "$(dirname "$0")/.." || exit 1
theme=plymouth/tide
passed=0
failed=0
check() {
    name=$1
    shift
    if "$@"; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "FAIL: $name"
    fi
}
# key GROUP KEY: KEY's value in [GROUP] of tide.plymouth.
key() {
    awk -v group="[$1]" -v key="$2" '
        /^\[/ { in_group = ($0 == group); next }
        in_group && index($0, key "=") == 1 { print substr($0, length(key) + 2); exit }
    ' "$theme/tide.plymouth"
}
# png_size FILE: "WIDTHxHEIGHT" from a PNG's header, or nothing if it isn't one.
png_size() {
    test "$(od -An -c -j1 -N3 "$1" 2>/dev/null | tr -d ' ')" = PNG || return 0
    # shellcheck disable=SC2046  # eight numbers, one per byte
    set -- $(od -An -tu1 -j16 -N8 "$1")
    echo "$(( ($1 << 24) + ($2 << 16) + ($3 << 8) + $4 ))x$(( ($5 << 24) + ($6 << 16) + ($7 << 8) + $8 ))"
}

check "the theme uses Plymouth's own two-step plugin" test "$(key 'Plymouth Theme' ModuleName)" = two-step
check "the theme is named tide, as the initramfs hooks find it by its file's name" \
    test "$(key 'Plymouth Theme' Name)" = tide
check "its images are where make install-splash puts them" \
    test "$(key two-step ImageDir)" = /usr/share/plymouth/themes/tide
check "the background is black from top to bottom" \
    test "$(key two-step BackgroundStartColor)$(key two-step BackgroundEndColor)" = 0x0000000x000000
check "no transition, and no end animation on boot" \
    test "$(key two-step Transition)/$(key boot-up UseEndAnimation)" = none/false
# Ubuntu's initramfs hook reads ImageDir and ModuleName with sed, line by
# line, and older Plymouths may not skip a comment.
check "the theme file has no comments for a hook to trip on" \
    test -z "$(grep -n '^[#;]' "$theme/tide.plymouth")"

# What two-step loads: lock.png, or no splash at all; entry.png and
# bullet.png, or no password prompt; the rest it does without.
for image in lock entry bullet watermark keyboard capslock; do
    check "$image.png is a PNG" test -n "$(png_size "$theme/$image.png")"
done
check "the logo and name fit a small screen" test "$(png_size "$theme/watermark.png" | cut -dx -f1)" -le 320
# Plymouth spaces bullets by the bullet image's width, so a field must hold
# a password's worth.
entry_width=$(png_size "$theme/entry.png" | cut -dx -f1)
bullet_width=$(png_size "$theme/bullet.png" | cut -dx -f1)
check "the field holds at least 12 bullets" test $((entry_width / bullet_width)) -ge 12

# The spinner: Plymouth plays throbber-0001.png on in order, until one is
# missing, over 2 s, so 60 frames of 12° turn it once a second.
frames=0
size=
while test -f "$theme/throbber-$(printf %04d $((frames + 1))).png"; do
    frames=$((frames + 1))
    this=$(png_size "$theme/throbber-$(printf %04d "$frames").png")
    test -n "$size" || size=$this
    check "throbber frame $frames is the first's size" test "$this" = "$size"
done
check "the spinner has 60 frames" test "$frames" -eq 60
check "and nothing past them" test -z "$(find "$theme" -name 'throbber-*.png' ! -name 'throbber-00[0-5][0-9].png' ! -name 'throbber-0060.png')"
# keymap-render.png must match the Plymouth it runs under, so it's copied
# from the distro's spinner theme as it's installed, never shipped.
check "keymap-render.png isn't shipped" test ! -e "$theme/keymap-render.png"

echo "theme_test.sh: $passed passed, $failed failed"
test "$failed" -eq 0
