#!/bin/sh
# Run on a Mac/Linux admin laptop with SSH access to Neon and the Pi.
set -eu
BASE_URL=https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main
die() { echo "wireguard-installer: $*" >&2; exit 1; }
log() { echo "wireguard-installer: $*" >&2; }
usage() {
    cat <<'EOF'
Usage: sh wireguard-installer-macos.command install HUB_ADDRESS DEVICE_LABEL [options]
  --ssh-key FILE    SSH public key to authorize on the Pi (.pub file).
                   Default: first available Neon identity .pub, then id_ed25519.pub/id_rsa.pub.
  --neon TARGET    SSH alias or user@host for Neon (default: neon). Requires root access.
The Pi login is pi. SSH prompts normally for its current password if needed.
Run from a laptop already connected to Neon as an admin/test WireGuard peer.
EOF
}
case "${1:-}" in -h|--help) usage; exit 0 ;; install) shift ;; *) usage >&2; exit 1 ;; esac
[ "$#" -ge 2 ] || die "supply the Pi address and a unique device label"
hub=$1; label=$2; shift 2
neon=neon; ssh_key=""
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || die "missing value for $1"
    case "$1" in
        --ssh-key) ssh_key=$2 ;;
        --neon) neon=$2 ;;
        *) die "unknown option: $1" ;;
    esac
    shift 2
done
case "$hub" in ''|-*|*[!a-zA-Z0-9._-]*) die "invalid hub address" ;; esac
case "$neon" in ''|-*|*[!a-zA-Z0-9@._-]*) die "invalid Neon SSH target" ;; esac
case "$label" in ''|[!a-zA-Z0-9]*|*[!a-zA-Z0-9._-]*) die "use a device label containing letters, digits, dots, underscores or hyphens" ;; esac
[ "${#label}" -le 63 ] || die "device label must be at most 63 characters"
for tool in ssh ssh-keygen curl awk; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
if [ -z "$ssh_key" ]; then
    # ssh -G prints configuration only. Never read or copy the private key.
    identities=$(ssh -G "$neon" 2>/dev/null | awk '$1=="identityfile" {sub(/^[^ \t]+[ \t]+/, ""); print}')
    while IFS= read -r identity; do
        case "$identity" in \~/*) identity=$HOME/${identity#??} ;; esac
        if [ -f "$identity.pub" ]; then ssh_key=$identity.pub; break; fi
    done <<EOF
$identities
EOF
    if [ -z "$ssh_key" ]; then
        for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
            if [ -f "$candidate" ]; then ssh_key=$candidate; break; fi
        done
    fi
fi
[ -n "$ssh_key" ] && [ -f "$ssh_key" ] || die "supply your SSH PUBLIC key using --ssh-key /path/to/key.pub"
ssh-keygen -l -f "$ssh_key" >/dev/null || die "invalid SSH public key file"
ssh_type=$(awk 'NR==1 {print $1}' "$ssh_key")
ssh_body=$(awk 'NR==1 {print $2}' "$ssh_key")
case "$ssh_type" in ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;; *) die "unsupported SSH public key type" ;; esac
case "$ssh_body" in ''|*[!a-zA-Z0-9+/=]*) die "invalid SSH public key encoding" ;; esac
ssh_identity=$ssh_key
case "$ssh_key" in *.pub) if [ -f "${ssh_key%.pub}" ]; then ssh_identity=${ssh_key%.pub}; fi ;; esac

# macOS TMPDIR paths can exceed the Unix socket path limit once %C is appended.
workdir=$(mktemp -d /tmp/pe-wg.XXXXXX) || die "cannot create temporary directory"
chmod 700 "$workdir"
control=$workdir/ssh-%C
cleanup() {
    ssh -o ControlPath="$control" -O exit "pi@$hub" >/dev/null 2>&1 || :
    ssh -o ControlPath="$control" -O exit "$neon" >/dev/null 2>&1 || :
    rm -rf "$workdir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
fetch() {
    if [ -n "$1" ]; then
        cp "$1" "$3" || die "cannot read the selected payload"
    else
        curl -fsSL --connect-timeout 10 --max-time 60 "$BASE_URL/$2" -o "$3" || die "payload download failed"
    fi
    [ -s "$3" ] || die "empty payload"
    sh -n "$3" || die "invalid payload shell syntax"
}
fetch "${PUREEDGE_WG_PI_PAYLOAD:-}" wireguard-pi.sh "$workdir/pi.sh"
fetch "${PUREEDGE_WG_NEON_PAYLOAD:-}" wireguard-neon.sh "$workdir/neon.sh"
pi_run() {
    # All arguments come from restricted alphabets, validated before this call.
    ssh -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=120 \
        -o ControlPath="$control" "pi@$hub" "sudo -n sh -s -- $*" < "$workdir/pi.sh"
}
log "checking Neon access; it must already recognize your SSH key"
ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=120 \
    -o ControlPath="$control" "$neon" \
    'test "$(id -u)" = 0 && systemctl is-active --quiet wg-quick@wg0.service' ||
    die "Neon needs root SSH access and an active wg0; check --neon and your SSH configuration"
log "preparing pi@$hub; enter its current SSH password if prompted"
device=$(pi_run prepare) || die "Pi preparation failed; no new peer was requested on Neon"
public_key=$(printf '%s\n' "$device" | sed -n 's/^PUBLIC_KEY=//p')
host_key=$(printf '%s\n' "$device" | sed -n 's/^HOST_KEY=//p')
case "$public_key" in *[!a-zA-Z0-9+/=]*) die "invalid device public key" ;; esac
[ "${#public_key}" = 44 ] || die "missing device public key"
case "$host_key" in ''|*[!a-zA-Z0-9+/=]*) die "missing or invalid Pi host public key" ;; esac
log "registering $label as a production peer (or reusing its existing enrollment)"
registration=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=120 \
    -o ControlPath="$control" "$neon" "sh -s -- $label $public_key" < "$workdir/neon.sh") ||
    die "Neon registration failed; the Pi retains its key for a safe retry"
address=$(printf '%s\n' "$registration" | sed -n 's/^ADDRESS=//p')
server_pub=$(printf '%s\n' "$registration" | sed -n 's/^SERVER_PUBLIC_KEY=//p')
case "$address" in ''|*[!0-9.]*) die "invalid peer address from Neon" ;; esac
case "$server_pub" in *[!a-zA-Z0-9+/=]*) die "invalid server public key" ;; esac
[ "${#server_pub}" = 44 ] || die "missing server public key"
log "installing the profile and authorizing your SSH key on $address"
pi_run install "$address" "$server_pub" drgb.vivianh.dev:51820 "$ssh_type" "$ssh_body" ||
    die "Pi installation failed; rerun with the SAME label and Pi. Its key and Neon enrollment are retained."

# Pin the host key learned over LAN instead of trusting a new host at the tunnel IP.
printf '%s ssh-ed25519 %s\n' "$address" "$host_key" > "$workdir/known_hosts"
log "verifying SSH over WireGuard from this laptop"
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes -i "$ssh_identity" \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$workdir/known_hosts" \
    "pi@$address" 'test "$(id -un)" = pi'; then
    log "profile installed, but remote SSH verification failed. Check this laptop's admin/test WireGuard connection and SSH key."
    printf 'Retry SSH: ssh -i "%s" pi@%s\n' "$ssh_identity" "$address" >&2
    exit 1
fi
printf '\nWireGuard and SSH verified. Both services are enabled at boot.\n'
printf 'Device: %s\nWireGuard IP: %s\n' "$label" "$address"
printf 'Connect: ssh -i "%s" pi@%s\n' "$ssh_identity" "$address"
