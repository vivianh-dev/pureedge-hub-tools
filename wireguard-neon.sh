#!/bin/sh
# Runs on Neon as root. Accepts only a device label and PUBLIC key.
set -eu
die() { echo "wireguard-neon: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root on Neon"
[ "$#" = 2 ] || [ "$#" = 3 ] || die "usage: sh wireguard-neon.sh DEVICE_LABEL PUBLIC_KEY [EXPIRY_EPOCH]"
label=$1; pubkey=$2
case "$label" in ''|[!a-zA-Z0-9]*|*[!a-zA-Z0-9._-]*) die "invalid device label" ;; esac
[ "${#label}" -le 63 ] || die "device label is too long"
case "$pubkey" in *[!a-zA-Z0-9+/=]*) die "invalid public key" ;; esac
[ "${#pubkey}" = 44 ] || die "invalid public key length"
if [ "$#" = 3 ]; then
    expires=$3
    case "$expires" in ''|*[!0-9]*) die "invalid expiration" ;; esac
    now=$(date +%s)
    [ "$expires" -gt "$now" ] && [ "$expires" -le "$((now + 86400))" ] || die "expiry must be within the next 24 hours"
fi
systemctl is-active --quiet wg-quick@wg0.service || die "Neon's wg0 service is inactive"
server_pub=$(wg show wg0 public-key)
[ -n "$server_pub" ] && [ "$server_pub" != '(none)' ] || die "Neon has no WireGuard public key"

# Fetch separately so a failed fleet command cannot become an empty list.
fleet=$(neon-fleet list --json) || die "cannot read Neon's fleet"
peer=$(printf '%s\n' "$fleet" | jq -c --arg label "$label" '.peers[] | select(.label == $label)')
if [ "$#" = 3 ]; then
    # Each customer bundle gets a new label. Never extend an existing peer's expiry.
    [ -z "$peer" ] || die "expiring support labels must be new; no expiry was extended"
    unit=pureedge-support-$label
    calendar=$(date -u -d "@$expires" '+%Y-%m-%d %H:%M:%S UTC')
    # Install the revocation mechanism BEFORE registering the peer. These are
    # persistent unit files, so revocation also runs after a Neon reboot.
    expiry_tmp=$(mktemp /usr/local/bin/.pureedge-expire.XXXXXX)
    cat > "$expiry_tmp" <<'EXPIRY'
#!/bin/sh
set -eu
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
label=$1; pubkey=$2
fleet=$(neon-fleet list --json)
id=$(printf '%s\n' "$fleet" | jq -r --arg label "$label" --arg key "$pubkey" \
    '.peers[] | select(.label == $label and .pubkey == $key and .class == "production") | .id')
if [ -n "$id" ]; then neon-fleet remove "$id"; fi
EXPIRY
    chmod 700 "$expiry_tmp"
    mv "$expiry_tmp" /usr/local/bin/pureedge-expire-support-peer
    service_tmp=$(mktemp /etc/systemd/system/.pureedge-support-service.XXXXXX)
    cat > "$service_tmp" <<EOF
[Unit]
Description=Revoke temporary PureEdge support peer $label
After=wg-quick@wg0.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/pureedge-expire-support-peer $label $pubkey
Restart=on-failure
RestartSec=60
EOF
    chmod 644 "$service_tmp"
    mv "$service_tmp" "/etc/systemd/system/$unit.service"
    timer_tmp=$(mktemp /etc/systemd/system/.pureedge-support-timer.XXXXXX)
    cat > "$timer_tmp" <<EOF
[Unit]
Description=Expire temporary PureEdge support peer $label
[Timer]
OnCalendar=$calendar
AccuracySec=1s
Persistent=true
[Install]
WantedBy=timers.target
EOF
    chmod 644 "$timer_tmp"
    mv "$timer_tmp" "/etc/systemd/system/$unit.timer"
    systemctl daemon-reload
    systemctl enable --now "$unit.timer"
    systemctl is-active --quiet "$unit.timer" || die "expiry timer is inactive; no peer registered"
    systemctl is-enabled --quiet "$unit.timer" || die "expiry timer is not enabled; no peer registered"
fi
if [ -z "$peer" ]; then
    neon-fleet add --class production --label "$label" --pubkey "$pubkey" >&2 ||
        die "registration failed; retry with the same label and device key"
    fleet=$(neon-fleet list --json) || die "cannot read the registered peer"
    peer=$(printf '%s\n' "$fleet" | jq -c --arg label "$label" '.peers[] | select(.label == $label)')
fi
printf '%s\n' "$peer" | jq -e --arg key "$pubkey" \
    '.class == "production" and .pubkey == $key' >/dev/null ||
    die "label is already assigned to a different key or peer class; nothing replaced"
address=$(printf '%s\n' "$peer" | jq -er '.ip')
printf 'ADDRESS=%s\nSERVER_PUBLIC_KEY=%s\n' "$address" "$server_pub"
