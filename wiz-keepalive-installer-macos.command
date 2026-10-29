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
# hub password for each one (factory default for these units: pi / DALInew).

MODE="$1"
[ -n "$MODE" ] || MODE="install"
[ $# -gt 0 ] && shift

PAYLOAD_URL="https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PAYLOAD="$HERE/wiz-keepalive.sh"

# macOS has no ip command, so work from ifconfig and route.
local_ipv4() {
    ifconfig | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
}

local_cidr() {
    base=$(local_ipv4)
    [ -n "$base" ] || return 1
    echo "$base" | awk -F. '{print $1"."$2"."$3".0/24"}'
}

# discover lists hosts on this machine's subnet that answer on the ports the
# hub web interface uses, so nobody has to know the hub address in advance.
discover() {
    if command -v nmap >/dev/null 2>&1; then
        nmap -sn -n -T4 --host-timeout 5s "$(local_cidr)" 2>/dev/null |
            awk '/Nmap scan report/{print $NF}'
    else
        base=$(local_ipv4 | awk -F. '{print $1"."$2"."$3}')
        for i in $(seq 1 254); do
            ping -c 1 -t 1 "$base.$i" >/dev/null 2>&1 && echo "$base.$i"
        done
    fi | while read -r h; do
        [ -n "$h" ] || continue
        if command -v nc >/dev/null 2>&1; then
            for p in 80 443 5500; do
                nc -z -G 1 -w 1 "$h" "$p" >/dev/null 2>&1 && { echo "$h  (hub, port $p)"; continue 2; }
            done
            echo "$h  (no hub ports open)"
        else
            echo "$h"
        fi
    done
}

if [ "$MODE" = "discover" ]; then
    discover
    exit 0
fi

if [ ! -f "$PAYLOAD" ]; then
    PAYLOAD=$(mktemp)
    curl -fsSL "$PAYLOAD_URL" -o "$PAYLOAD" || { echo "could not download $PAYLOAD_URL"; exit 1; }
fi

if [ $# -gt 0 ]; then
    HUBS="$*"
else
    printf "hub IP address(es), space separated: "
    read -r HUBS
fi
[ -n "$HUBS" ] || { echo "no hub address given"; exit 1; }

for HUB in $HUBS; do
    echo "== $HUB =="
    scp -q "$PAYLOAD" "pi@$HUB:/tmp/wiz-keepalive.sh" || { echo "== $HUB failed to copy"; continue; }
    ssh "pi@$HUB" "sudo sh /tmp/wiz-keepalive.sh $MODE; rm -f /tmp/wiz-keepalive.sh" \
        && echo "== $HUB ok" \
        || echo "== $HUB failed (check password and that the hub is reachable)"
done
