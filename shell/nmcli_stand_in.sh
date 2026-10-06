#!/bin/sh
#
# A stand-in for nmcli, for shell/shell_test.sh: the shell's own calls,
# answered as NetworkManager's would answer them.
#
#   LC_ALL=C nmcli_stand_in.sh -t -f NAME,UUID,TYPE,ACTIVE,STATE connection show
#   nmcli_stand_in.sh monitor
#
# The list is a Wi-Fi network, a VPN that's up, a WireGuard VPN that's
# down with a colon in its name, and a wired connection. As the nmcli(1)
# manual in NetworkManager 1.54.3 has it, terse output escapes ":" and "\"
# by default, and a script calls it as LC_ALL=C nmcli, so the list is given
# only in the C locale. The monitor reports nothing, and waits as
# gsettings_stand_in.sh's does.

# The count with the words, so that an argument with a space can't pass
# for two.
case "$#|$*" in
    "1|monitor")
        exec tail --pid="$PPID" -f /dev/null
        ;;
    "5|-t -f NAME,UUID,TYPE,ACTIVE,STATE connection show")
        if test "${LC_ALL:-}" != C; then
            echo "nmcli: the load test's stand-in lists connections only for LC_ALL=C" >&2
            exit 2
        fi
        cat <<'LIST'
Home:6c0d4c3e-1a2b-4c5d-8e9f-000000000001:802-11-wireless:yes:activated
Office VPN:6c0d4c3e-1a2b-4c5d-8e9f-000000000002:vpn:yes:activated
Lab\: WireGuard:6c0d4c3e-1a2b-4c5d-8e9f-000000000003:wireguard:no:
Wired connection 1:6c0d4c3e-1a2b-4c5d-8e9f-000000000004:802-3-ethernet:no:
LIST
        ;;
    *)
        echo "nmcli: the load test's stand-in doesn't answer $*" >&2
        exit 2
        ;;
esac
