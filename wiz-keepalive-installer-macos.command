#!/bin/sh
# wiz-keepalive-installer-macos.command
#
# Installs the WiZ keepalive sweep onto a Raspberry Pi hub, from macOS.
# The sweep then runs on the hub itself.
#
# One-liner (no file needed):
#   curl -fsSL https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive-installer-macos.command | sh -s -- install 192.168.1.50
#
#   sh wiz-keepalive-installer-macos.command install 192.168.1.50 [more IPs...]
#   sh wiz-keepalive-installer-macos.command remove  192.168.1.50
#   sh wiz-keepalive-installer-macos.command status  192.168.1.50
#   sh wiz-keepalive-installer-macos.command discover
#
# Requires ssh and scp (both built into macOS). You will be asked for the
# hub password, once per hub (factory default for these units: pi / DALInew).

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

# macOS has no ip command, so work from ifconfig and route.
local_ipv4() {
    _dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    if [ -n "$_dev" ]; then
        ifconfig "$_dev" 2>/dev/null | awk '/inet /{print $2; exit}'
    else
        ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
    fi
}

local_cidr() {
    _ip=$(local_ipv4)
    [ -n "$_ip" ] || return 1
    _dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    if [ -n "$_dev" ]; then
        _mask=$(ifconfig "$_dev" 2>/dev/null | awk '/netmask/{print $2; exit}' | sed 's/^0x//')
        if [ -n "$_mask" ]; then
            _len=$(printf '%08x' "$_mask" | awk '{n=0; for(i=1;i<=length($0);i++){c=substr($0,i,1); n=n*2+(c=="1"?1:0)}; print 32-n}')
            [ "$_len" -ge 8 ] 2>/dev/null && [ "$_len" -le 30 ] 2>/dev/null && { echo "$_ip/$_len"; return 0; }
        fi
    fi
    echo "$_ip" | awk -F. '{print $1"."$2"."$3".0/24"}'
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
            ping -c 1 -t 1 "$base.$i" >/dev/null 2>&1 && echo "$base.$i"
        done > "$tmp"
    fi
    while read -r h; do
        [ -n "$h" ] || continue
        if command -v nc >/dev/null 2>&1; then
            found=""
            for p in 22 80 443; do
                nc -z -G 1 -w 1 "$h" "$p" >/dev/null 2>&1 && found="$found $p"
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
    # sudo -n so the hub either has passwordless sudo for pi or fails
    # immediately, instead of hanging on a prompt nobody can see.
    if ssh "pi@$HUB" "cat > /tmp/wiz-keepalive.sh && sudo -n sh /tmp/wiz-keepalive.sh '$MODE'; rc=\$?; rm -f /tmp/wiz-keepalive.sh; exit \$rc" < "$PAYLOAD"; then
        echo "== $HUB ok"
    else
        echo "== $HUB failed (check password and that the hub is reachable)"
        echo "   if the hub wants a sudo password, log in with ssh pi@$HUB and run: sudo sh /tmp/wiz-keepalive.sh $MODE"
        rc=1
    fi
done
exit $rc
