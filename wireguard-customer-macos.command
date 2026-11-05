#!/bin/sh
# Customer installer. No Neon account, admin SSH key, or laptop VPN required.
set -eu
BASE_URL=https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main
die() { echo "pureedge-support: $*" >&2; exit 1; }
log() { echo "pureedge-support: $*" >&2; }
usage() {
    echo 'Usage: sh wireguard-customer-macos.command install HUB_IP BUNDLE_URL_OR_FILE'
}
case "${1:-}" in --help|-h) usage; exit 0 ;; install) shift ;; *) usage >&2; exit 1 ;; esac
[ "$#" = 2 ] || die "supply the hub IP and the encrypted support bundle URL"
hub=$1; bundle=$2
case "$hub" in ''|-*|*[!a-zA-Z0-9._-]*) die "invalid hub address" ;; esac
umask 077
workdir=$(mktemp -d /tmp/pe-support.XXXXXX)
remote_dir=""
control=$workdir/s-%C
cleanup() {
    if [ -n "$remote_dir" ]; then
        ssh -o ControlPath="$control" -o BatchMode=yes -o ConnectTimeout=5 \
            "pi@$hub" "rm -f $remote_dir/install.sh; rmdir $remote_dir" >/dev/null 2>&1 || :
    fi
    ssh -o ControlPath="$control" -O exit "pi@$hub" >/dev/null 2>&1 || :
    rm -rf "$workdir"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
age_bin=${PUREEDGE_AGE_BIN:-}
if [ -z "$age_bin" ] && command -v age >/dev/null 2>&1; then age_bin=$(command -v age); fi
if [ -z "$age_bin" ]; then
    # Official age v1.3.2 binaries, with SHA-256 pinned to the release assets.
    case "$(uname -s)/$(uname -m)" in
        Darwin/x86_64) platform=darwin-amd64; digest=1d1e4bc66e1427edad7739ae7616157de0e79db8b6d2a1497d7d9925fb06a539 ;;
        Darwin/arm64) platform=darwin-arm64; digest=e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5 ;;
        Linux/x86_64) platform=linux-amd64; digest=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10 ;;
        Linux/aarch64) platform=linux-arm64; digest=6b8dc4333c53a5a57c9e5834e3a48f92605d7154014cd07269ff3327db5d37f4 ;;
        *) die "install age from https://age-encryption.org before running this installer" ;;
    esac
    log "downloading the support bundle decryption tool"
    curl -fsSL --connect-timeout 10 --max-time 120 \
        "https://github.com/FiloSottile/age/releases/download/v1.3.2/age-v1.3.2-$platform.tar.gz" -o "$workdir/age.tgz"
    if command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$workdir/age.tgz" | awk '{print $1}')
    else
        actual=$(sha256sum "$workdir/age.tgz" | awk '{print $1}')
    fi
    [ "$actual" = "$digest" ] || die "decryption tool checksum failed"
    tar -xzf "$workdir/age.tgz" -C "$workdir" age/age
    age_bin=$workdir/age/age
fi
case "$bundle" in
    https://*) curl -fsSL --connect-timeout 10 --max-time 60 "$bundle" -o "$workdir/profile.age" ;;
    *) [ -f "$bundle" ] || die "bundle must be a local file or HTTPS URL"; cp "$bundle" "$workdir/profile.age" ;;
esac
log "enter the support bundle password supplied separately"
"$age_bin" --decrypt -o "$workdir/profile" "$workdir/profile.age" || die "cannot decrypt the bundle; nothing installed"
expires=$(awk -F= '$1=="EXPIRES" {print $2}' "$workdir/profile")
case "$expires" in ''|*[!0-9]*) die "invalid support bundle" ;; esac
[ "$(date +%s)" -lt "$expires" ] || die "this support bundle has expired; request a new one"
if [ -n "${PUREEDGE_WG_PI_PAYLOAD:-}" ]; then
    cp "$PUREEDGE_WG_PI_PAYLOAD" "$workdir/install.sh"
else
    curl -fsSL --connect-timeout 10 --max-time 60 "$BASE_URL/wireguard-pi.sh" -o "$workdir/install.sh"
fi
sh -n "$workdir/install.sh" || die "invalid installer payload"
pi_ssh() {
    ssh -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPersist=120 \
        -o ControlPath="$control" "pi@$hub" "$@"
}
log "connecting to the Pi; enter its current login password when prompted"
candidate=$(pi_ssh 'umask 077; mktemp -d /tmp/pe-wg.XXXXXX') || die "cannot connect to the Pi"
suffix=${candidate#/tmp/pe-wg.}
[ "$suffix" != "$candidate" ] || die "invalid temporary directory from Pi"
case "$suffix" in ''|*[!a-zA-Z0-9]*) die "invalid temporary directory from Pi" ;; esac
remote_dir=$candidate
pi_ssh "cat > $remote_dir/install.sh" < "$workdir/install.sh"
pi_ssh "sudo -n sh $remote_dir/install.sh prepare-bundle" || die "Pi preparation failed (passwordless sudo and a supported kernel are required)"
pi_ssh "sudo -n sh $remote_dir/install.sh import-bundle" < "$workdir/profile" ||
    die "installation failed; retry this bundle on the SAME Pi before its expiry"
address=$(awk -F= '$1=="ADDRESS" {print $2}' "$workdir/profile")
expiry_utc=$(awk -F= '$1=="EXPIRES_UTC" {print $2}' "$workdir/profile")
printf '\nSupport tunnel handshake verified. SSH is enabled for support.\n'
printf 'Device tunnel IP: %s\nAccess expires: %s\n' "$address" "$expiry_utc"
printf 'Support must still verify its SSH login. Use this bundle on one Pi only.\n'
