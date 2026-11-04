#!/bin/sh
#
# Tests for bin/tide-fill, against fake rbw, wtype and tide-kwin-paste on
# PATH, with the real jq. A real vault and a real compositor can only be
# checked in a session.

cd "$(dirname "$0")/.." || exit 1
cmd=$PWD/bin/tide-fill

passes=0
failures=0
check() {
    _name=$1
    shift
    if "$@"; then passes=$((passes + 1)); else
        failures=$((failures + 1))
        printf 'FAIL: %s\n' "$_name" >&2
    fi
}
contains() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
fake=$tmp/bin
mkdir "$fake"
export FAKE_DIR="$tmp" XDG_CONFIG_HOME="$tmp/config" XDG_RUNTIME_DIR="$tmp"
mkdir -p "$XDG_CONFIG_HOME/tide"

# rbw: unlocked unless $FAKE_LOCKED; three logins, a card and a note
# (rbw 1.15's type field, which $FAKE_OLD_RBW refuses as an older rbw
# does), one login without a user, one without a user; get
# prints the field with a newline, as rbw does; code fails for the login
# with no TOTP. Every call is logged.
cat > "$fake/rbw" <<'FAKE'
#!/bin/sh
printf 'rbw %s\n' "$*" >> "$FAKE_DIR/log"
case "$1" in
    unlocked) test -z "${FAKE_LOCKED:-}" ;;
    unlock) echo unlocked >> "$FAKE_DIR/log" ;;
    list)
        case "$3" in
            *,type)
                if test -n "${FAKE_OLD_RBW:-}"; then
                    echo "error: unknown field type" >&2
                    exit 1
                fi
                printf 'id-1\tgithub.com\tme@example.com\tweb\tLogin\nid-2\twifi\t\t\tLogin\nid-3\tbank\t\tmoney\tLogin\nid-4\tVisa\t\t\tCard\nid-5\tNotes\t\t\tNote\n' ;;
            *) printf 'id-1\tgithub.com\tme@example.com\tweb\nid-2\twifi\t\t\nid-3\tbank\t\tmoney\nid-4\tVisa\t\t\nid-5\tNotes\t\t\n' ;;
        esac ;;
    get)
        case "$3 $4" in
            "password id-1") echo 'hunter2' ;;
            "username id-1") echo 'me@example.com' ;;
            *) echo "rbw get: couldn't find entry" >&2; exit 1 ;;
        esac ;;
    code)
        case "$2" in
            id-1) echo 123456 ;;
            *) echo "rbw code: not a totp secret" >&2; exit 1 ;;
        esac ;;
esac
FAKE
# wtype and tide-kwin-paste keep what they're asked to type, from stdin.
cat > "$fake/wtype" <<'FAKE'
#!/bin/sh
printf 'wtype %s\n' "$*" >> "$FAKE_DIR/log"
cat > "$FAKE_DIR/typed"
FAKE
cat > "$fake/tide-kwin-paste" <<'FAKE'
#!/bin/sh
printf 'tide-kwin-paste %s\n' "$*" >> "$FAKE_DIR/log"
cat > "$FAKE_DIR/typed"
FAKE
chmod +x "$fake"/*
base=$tmp/base
mkdir "$base"
for t in jq tr cat mktemp rm printf grep chmod awk; do
    p=$(command -v "$t") && ln -s "$p" "$base/$t"
done
export PATH="$fake:$base"

reset() {
    rm -f "$tmp/log" "$tmp/typed" "$XDG_CONFIG_HOME/tide/snippets.json" "$XDG_CONFIG_HOME/tide/snippets.local.json"
    unset FAKE_LOCKED FAKE_OLD_RBW XDG_CURRENT_DESKTOP
}

# --- list ----------------------------------------------------------------------

reset
printf '{"Home address": "1 Main St\\nSpringfield", "Phone": "555-0100"}\n' > "$XDG_CONFIG_HOME/tide/snippets.json"
printf '{"Phone": "555-0199"}\n' > "$XDG_CONFIG_HOME/tide/snippets.local.json"
out=$("$cmd" list)
check "list exits 0" test $? -eq 0
check "snippets come first, one line each, the local file's value winning by name" \
    contains "$out" "$(printf 'snippet\tHome address\ttext\tHome address\tSnippet\nsnippet\tPhone\ttext\tPhone\tSnippet')"
check "a login has a row each for its username, password and 2FA code" \
    contains "$out" "$(printf 'login\tid-1\tusername\tgithub.com · username\tme@example.com · web\nlogin\tid-1\tpassword\tgithub.com · password\tme@example.com · web\nlogin\tid-1\ttotp\tgithub.com · 2FA code\tme@example.com · web')"
check "a login with no user has no username row, and says Bitwarden for no folder" \
    contains "$out" "$(printf 'login\tid-2\tpassword\twifi · password\tBitwarden\nlogin\tid-2\ttotp\twifi · 2FA code\tBitwarden')"
check "and no row for a username it hasn't" test -z "$(printf '%s\n' "$out" | grep "id-2	username")"
check "a login with a folder but no user keeps the folder as the folder, not the user" \
    test "$(printf '%s\n' "$out" | grep 'id-3	password')" = "$(printf 'login\tid-3\tpassword\tbank · password\tmoney')"
check "and has no username row" test -z "$(printf '%s\n' "$out" | grep "id-3	username")"
check "list never asks rbw for a secret" test -z "$(grep -e 'rbw get' -e 'rbw code' "$tmp/log")"
check "nor shows one" test -z "$(printf '%s' "$out" | grep -e hunter2 -e 555-0199x)"
check "a card or note has no rows: it has no password or 2FA code" \
    test -z "$(printf '%s\n' "$out" | grep -e id-4 -e id-5)"

reset
export FAKE_OLD_RBW=1
out=$("$cmd" list 2>&1)
check "an rbw before 1.15, without the type field, still lists" test $? -eq 0
check "every login, through the listing without it" \
    contains "$out" "$(printf 'login\tid-3\tpassword\tbank · password\tmoney')"

reset
FAKE_LOCKED=1
export FAKE_LOCKED
out=$("$cmd" list)
check "a locked vault is one Unlock row, not a pinentry behind the picker" \
    test "$out" = "$(printf 'unlock\t-\t-\tUnlock Bitwarden\trbw asks for your master password')"
check "and rbw isn't asked to list" test -z "$(grep 'rbw list' "$tmp/log")"

reset
printf '["not", "an object"]\n' > "$XDG_CONFIG_HOME/tide/snippets.json"
out=$("$cmd" list 2>"$tmp/err")
check "a snippets file that isn't an object is left out, and the rest still lists" contains "$out" "github.com · password"
check "saying which file and why" contains "$(cat "$tmp/err")" "snippets.json: not an object of name to text"

reset
rm "$fake/rbw"
out=$("$cmd" list 2>&1)
check "without rbw, just the snippets, and no error" test $? -eq 0
cat > "$fake/rbw" <<'FAKE'
#!/bin/sh
printf 'rbw %s\n' "$*" >> "$FAKE_DIR/log"
case "$1" in
    unlocked) test -z "${FAKE_LOCKED:-}" ;;
    unlock) echo unlocked >> "$FAKE_DIR/log" ;;
    list)
        case "$3" in
            *,type)
                if test -n "${FAKE_OLD_RBW:-}"; then
                    echo "error: unknown field type" >&2
                    exit 1
                fi
                printf 'id-1\tgithub.com\tme@example.com\tweb\tLogin\nid-2\twifi\t\t\tLogin\nid-3\tbank\t\tmoney\tLogin\nid-4\tVisa\t\t\tCard\nid-5\tNotes\t\t\tNote\n' ;;
            *) printf 'id-1\tgithub.com\tme@example.com\tweb\nid-2\twifi\t\t\nid-3\tbank\t\tmoney\nid-4\tVisa\t\t\nid-5\tNotes\t\t\n' ;;
        esac ;;
    get)
        case "$3 $4" in
            "password id-1") echo 'hunter2' ;;
            "username id-1") echo 'me@example.com' ;;
            *) echo "rbw get: couldn't find entry" >&2; exit 1 ;;
        esac ;;
    code)
        case "$2" in
            id-1) echo 123456 ;;
            *) echo "rbw code: not a totp secret" >&2; exit 1 ;;
        esac ;;
esac
FAKE
chmod +x "$fake/rbw"

# --- type ----------------------------------------------------------------------

reset
"$cmd" type login id-1 password
check "a password is typed exactly, without rbw's newline" test "$(cat "$tmp/typed"; printf x)" = "hunter2x"
check "by wtype, from stdin, not an argument" test "$(grep wtype "$tmp/log")" = "wtype -"
check "through rbw get --field password" contains "$(cat "$tmp/log")" "rbw get --field password id-1"

reset
"$cmd" type login id-1 totp
check "a 2FA code comes from rbw code" test "$(cat "$tmp/typed")" = "123456"

reset
out=$("$cmd" type login id-2 totp 2>&1)
check "a login without a TOTP fails" test $? -eq 1
check "saying rbw's reason" contains "$out" "rbw couldn't get the totp: rbw code: not a totp secret"
check "and types nothing" test ! -e "$tmp/typed"

reset
printf '{"Home address": "1 Main St\\nSpringfield\\n"}\n' > "$XDG_CONFIG_HOME/tide/snippets.json"
"$cmd" type snippet "Home address"
check "a snippet is typed as written, newlines and all" \
    test "$(cat "$tmp/typed"; printf x)" = "$(printf '1 Main St\nSpringfield\nx')"

reset
XDG_CURRENT_DESKTOP=KDE
export XDG_CURRENT_DESKTOP
"$cmd" type login id-1 username
check "on Plasma it types through KWin's fake-input" test "$(grep tide-kwin-paste "$tmp/log")" = "tide-kwin-paste --type"
check "the username" test "$(cat "$tmp/typed")" = "me@example.com"

reset
printf '{"Phone": "555"}\n' > "$XDG_CONFIG_HOME/tide/snippets.json"
out=$("$cmd" type snippet Nothing 2>&1)
check "a snippet that isn't there fails" test $? -eq 1
check "naming it" contains "$out" "no snippet named Nothing"
check "and types nothing" test ! -e "$tmp/typed"

reset
out=$("$cmd" type login id-1 notes 2>&1)
check "an unknown field is a usage error" test $? -eq 2

# --- unlock --------------------------------------------------------------------

reset
"$cmd" unlock
check "unlock runs rbw unlock" contains "$(cat "$tmp/log")" "rbw unlock"

printf 'tide-fill_test: %d passed, %d failed\n' "$passes" "$failures"
test "$failures" -eq 0
