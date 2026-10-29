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
#
# Requires ssh and scp (both built into macOS). You will be asked for the
# hub password for each one (factory default for these units: pi / DALInew).

MODE="$1"
[ -n "$MODE" ] || MODE="install"
[ $# -gt 0 ] && shift

PAYLOAD_URL="https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh"
HERE=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
PAYLOAD="$HERE/wiz-keepalive.sh"

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
