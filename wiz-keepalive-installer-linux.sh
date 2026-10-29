#!/bin/sh
# wiz-keepalive-installer-linux.sh
#
# Installs the WiZ keepalive sweep onto a Raspberry Pi hub, from Linux.
# The sweep then runs on the hub itself.
#
# One-liner (no file needed):
#   curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-linux.sh | sh -s -- install 192.168.1.50
#
#   sh wiz-keepalive-installer-linux.sh install 192.168.1.50 [more IPs...]
#   sh wiz-keepalive-installer-linux.sh remove  192.168.1.50
#   sh wiz-keepalive-installer-windows.ps1 status 192.168.1.50
#   sh wiz-keepalive-installer-linux.sh discover
#
# Requires ssh and scp. You will be asked for the hub password, once per hub
# (factory default for these units: pi / DALInew).

MODE="$1"
case "$MODE" in
    install|remove|status|run|discover) ;;
    *) MODE="" ;;
esac
[ $# -gt 0 ] && shift

PAYLOAD_URL="https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PAYLOAD="$HERE/wiz-keepalive.sh"
OWN_PAYLOAD=""
cleanup() { [ -n "$OWN_PAYLOAD" ] && rm -f "$OWN_PAYLOAD"; }
trap cleanup EXIT INT TERM

# The interface that carries traffic to the rest of the network.
local_iface() {
    _dev=$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    if [ -z "$_dev" ]; then
        _dev=$(ip -4 addr show scope global 2>/dev/null |
            awk '/:/ {name=$2; sub(/:$/,"",name); if (name !~ /^(wg|tun|tap|lo)/) {print name; exit}}')
    fi
    [ -n "$_dev" ] || return 1
    printf '%s\n' "$_dev"
}

local_cidr() {
    _dev=$(local_iface) || return 1
    _addr=$(ip -4 addr show dev "$_dev" 2>/dev/null | awk '/inet /{print $2; exit}')
    [ -n "$_addr" ] || return 1
    printf '%s\n' "$_addr"
}

# discover lists hosts on this machine's subnet that look like a hub, so
# nobody has to know the hub address in advance. These are candidates, not a
# confirmed identification.
discover() {
    cidr=$(local_cidr) || { echo "could not determine this machine's network"; return 1; }
    echo "scanning $cidr for hosts that look like a hub"
    tmp=$(mktemp) || return 1
    if command -v nmap >/dev/null 2>&1; then
        nmap -sn -n -T4 --host-timeout 5s "$cidr" 2>/dev/null | awk '/Nmap scan report/{print $NF}' > "$tmp"
    else
        ip=${cidr%/*}; base=${ip%.*}
        for i in $(seq 1 254); do
            ping -c 1 -W 1 "$base.$i" >/dev/null 2>&1 && echo "$base.$i"
        done > "$tmp"
    fi
    while read -r h; do
        [ -n "$h" ] || continue
        if command -v nc >/dev/null 2>&1; then
            found=""
            for p in 22 80 443; do
                nc -z -w 1 "$h" "$p" >/dev/null 2>&1 && found="$found $p"
            done
            if [ -n "$found" ]; then
                echo "  $h  candidate (ports open:$found)"
            else
                echo "  $h  no ssh or web ports open"
            fi
        else
            echo "  $h  (nc not available, cannot check ports)"
        fi
    done < "$tmp"
    rm -f "$tmp"
    return 0
}

if [ "$MODE" = "discover" ]; then
    discover
    exit $?
fi

if [ ! -f "$PAYLOAD" ]; then
    PAYLOAD=$(mktemp) || { echo "could not create a temp file"; exit 1; }
    OWN_PAYLOAD="$PAYLOAD"
    curl -fsSL "$PAYLOAD_URL" -o "$PAYLOAD" || { echo "could not download $PAYLOAD_URL"; exit 1; }
fi

if [ $# -gt 0 ]; then
    HUBS="$*"
else
    # Read from the terminal, not stdin, so this still works when the script
    # itself is being piped in.
    if [ -r /dev/tty ]; then
        printf "hub IP address(es), space separated: " > /dev/tty
        read -r HUBS < /dev/tty
    else
        HUBS=""
    fi
fi
[ -n "$HUBS" ] || { echo "no hub address given"; exit 1; }

rc=0
for HUB in $HUBS; do
    echo "== $HUB =="
    # One SSH connection: the payload is streamed to the hub over stdin, so
    # the SSH password is asked for once. sudo -n means the hub either has
    # passwordless sudo for pi or it fails immediately with a clear message,
    # instead of the command hanging on a prompt nobody can see.
    # The remote exit status is captured before cleanup, so a failed install
    # is not reported as a success.
    if ssh "pi@$HUB" "cat > /tmp/wiz-keepalive.sh && sudo -n sh /tmp/wiz-keepalive.sh '$MODE'; rc=\$?; rm -f /tmp/wiz-keepalive.sh; exit \$rc" < "$PAYLOAD"; then
        echo "== $HUB ok"
    else
        echo "== $HUB failed (check password and that the hub is reachable)"
        echo "   if the hub wants a sudo password, log in with ssh pi@$HUB and run: sudo sh /tmp/wiz-keepalive.sh $MODE"
        rc=1
    fi
done
exit $rc
