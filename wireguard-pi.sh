#!/bin/sh
# Runs on a Debian/Raspberry Pi OS device as root. Never exports private keys.
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH
export PATH
WG_DIR=/etc/wireguard
INTERFACE=wg-neon
KEY=$WG_DIR/$INTERFACE.key
CONF=$WG_DIR/$INTERFACE.conf
MARKER='# Managed by pureedge-hub-tools wireguard-pi.sh'
die() { echo "wireguard-pi: $*" >&2; exit 1; }
log() { echo "wireguard-pi: $*" >&2; }
valid_wg_key() {
    [ "${#1}" = 44 ] || return 1
    case "$1" in *[!a-zA-Z0-9+/=]*) return 1 ;; esac
}
check_profile() {
    [ ! -L "$KEY" ] && [ ! -L "$CONF" ] || die "refusing symlinked WireGuard files"
    if [ -e "$CONF" ]; then
        [ "$(head -n 1 "$CONF")" = "$MARKER" ] || die "$CONF exists and is not managed by this installer"
        [ -s "$KEY" ] || die "existing profile has no saved key; restore it before retrying"
    fi
}
check_routes() {
    # Reject overlapping local subnets before adding the fleet /16 route.
    routes=$(ip -4 route show scope link) || die "cannot inspect local routes"
    printf '%s\n' "$routes" | awk -v own="$INTERFACE" '
        function number(s, a) {split(s,a,"."); return a[1]*16777216+a[2]*65536+a[3]*256+a[4]}
        / dev / {
            for(i=1;i<NF;i++) if($i=="dev" && $(i+1)==own) next
            if($1 !~ /^[0-9]+\./) next
            split($1,p,"/"); bits=(p[2]=="" ? 32 : p[2]); size=2^(32-bits)
            lo=int(number(p[1])/size)*size; hi=lo+size-1
            if(lo<=number("10.88.255.255") && hi>=number("10.88.0.0")) exit 1
        }' || die "a local subnet overlaps 10.88.0.0/16; installation stopped"
}

[ "$(id -u)" = 0 ] || die "use sudo to run this script"
[ "$#" -ge 1 ] || die "usage: wireguard-pi.sh prepare | install ADDRESS SERVER_PUBKEY ENDPOINT SSH_TYPE SSH_BODY | status"
action=$1; shift
case "$action" in prepare|prepare-bundle|install|import-bundle|status) ;; *) die "unknown action: $action" ;; esac
[ -d /run/systemd/system ] || die "a running systemd is required"
command -v flock >/dev/null 2>&1 || die "flock from util-linux is required"
exec 9>/run/lock/pureedge-wireguard.lock
flock -n 9 || die "another WireGuard installation is running"
umask 077
check_profile

if [ "$action" = import-bundle ]; then
    [ "$#" = 0 ] || die "import-bundle reads its data from standard input"
    bundle_tmp=$(mktemp)
    trap 'rm -f "$bundle_tmp"' 0
    # Treat the decrypted bundle as data. Never source it or execute its contents.
    cat > "$bundle_tmp"
    field() {
        awk -v key="$1" 'index($0,key "=")==1 {n++; value=substr($0,length(key)+2)} END {if(n!=1) exit 1; print value}' "$bundle_tmp"
    }
    [ "$(field VERSION)" = 1 ] || die "unsupported bundle version"
    expires=$(field EXPIRES)
    case "$expires" in ''|*[!0-9]*) die "invalid bundle expiration" ;; esac
    [ "$(date +%s)" -lt "$expires" ] || die "this support bundle has expired"
    private_key=$(field PRIVATE_KEY)
    valid_wg_key "$private_key" || die "invalid private key in bundle"
    address=$(field ADDRESS); server_pub=$(field SERVER_PUBLIC_KEY)
    endpoint=$(field ENDPOINT); ssh_type=$(field SSH_TYPE); ssh_body=$(field SSH_BODY)
    # Validate the key with WireGuard before touching the saved key.
    printf '%s\n' "$private_key" | wg pubkey >/dev/null 2>&1 || die "invalid WireGuard private key"
    install -d -m 700 "$WG_DIR"
    if [ -e "$KEY" ]; then
        printf '%s\n' "$private_key" | cmp -s - "$KEY" || die "Pi already has a different device key; nothing replaced"
    else
        key_tmp=$(mktemp "$WG_DIR/.wg-neon-key.XXXXXX")
        printf '%s\n' "$private_key" > "$key_tmp"
        chmod 600 "$key_tmp"
        chown root:root "$key_tmp"
        mv "$key_tmp" "$KEY"
    fi
    unset private_key
    rm -f "$bundle_tmp"
    trap - 0
    action=install
    set -- "$address" "$server_pub" "$endpoint" "$ssh_type" "$ssh_body"
fi

case "$action" in
prepare|prepare-bundle)
    [ "$#" = 0 ] || die "prepare takes no arguments"
    getent passwd pi >/dev/null || die "the pi account does not exist"
    missing=0
    for tool in wg wg-quick sshd ip ssh-keygen; do
        command -v "$tool" >/dev/null 2>&1 || missing=1
    done
    if [ "$missing" = 1 ]; then
        command -v apt-get >/dev/null 2>&1 || die "apt-get is required to install WireGuard and OpenSSH"
        log "installing wireguard-tools and openssh-server (no OS or firmware upgrade)"
        apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update >&2
        DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=30 \
            install -y --no-install-recommends wireguard-tools openssh-server iproute2 >&2
    fi
    check_routes
    # Fail on unsupported kernels before enrolling anything on Neon.
    ip link add wgn-check type wireguard || die "kernel WireGuard support is unavailable (no kernel changes made)"
    ip link delete wgn-check
    install -d -m 700 "$WG_DIR"
    if [ "$action" = prepare ] && [ ! -e "$KEY" ]; then
        key_tmp=$(mktemp "$WG_DIR/.wg-neon-key.XXXXXX")
        if ! wg genkey > "$key_tmp"; then rm -f "$key_tmp"; die "key generation failed"; fi
        chmod 600 "$key_tmp"
        mv "$key_tmp" "$KEY"
    fi
    if [ "$action" = prepare ]; then
        chown root:root "$KEY"
        chmod 600 "$KEY"
        public_key=$(wg pubkey < "$KEY") || die "saved private key is invalid"
        valid_wg_key "$public_key" || die "invalid device public key"
        printf 'PUBLIC_KEY=%s\n' "$public_key"
    fi
    # Host public keys are returned over the already-authenticated LAN SSH session.
    [ -s "/etc/ssh/ssh_host_ed25519_key.pub" ] || die "the Pi needs an Ed25519 SSH host key"
    awk '$1=="ssh-ed25519" {print "HOST_KEY=" $2}' "/etc/ssh/ssh_host_ed25519_key.pub"
    ;;
install)
    [ "$#" = 5 ] || die "install needs ADDRESS SERVER_PUBKEY ENDPOINT SSH_TYPE SSH_BODY"
    address=$1; server_pub=$2; endpoint=$3; ssh_type=$4; ssh_body=$5
    printf '%s\n' "$address" | awk -F. 'NF!=4 || $1!=10 || $2!=88 || $3<2 || $3>255 || $4<0 || $4>255 {exit 1}' || die "invalid production peer address"
    case "$address" in *[!0-9.]*) die "invalid peer address" ;; esac
    valid_wg_key "$server_pub" || die "invalid server public key"
    case "$endpoint" in ''|-*|*[!a-zA-Z0-9.:-]*) die "invalid endpoint" ;; esac
    case "$ssh_type" in ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;; *) die "unsupported SSH public key type" ;; esac
    case "$ssh_body" in ''|*[!a-zA-Z0-9+/=]*) die "invalid SSH public key" ;; esac
    [ -s "$KEY" ] || die "run prepare first"
    check_routes
    home_dir=$(getent passwd pi | cut -d: -f6)
    [ -n "$home_dir" ] && [ -d "$home_dir" ] || die "pi has no home directory"
    ssh_dir=$home_dir/.ssh
    auth=$ssh_dir/authorized_keys
    [ ! -L "$ssh_dir" ] && [ ! -L "$auth" ] || die "refusing symlinked SSH authorization paths"
    group=$(id -gn pi)
    install -d -o pi -g "$group" -m 700 "$ssh_dir"
    ssh_key_tmp=$(mktemp "$ssh_dir/.neon-key.XXXXXX")
    printf '%s %s\n' "$ssh_type" "$ssh_body" > "$ssh_key_tmp"
    if ! ssh-keygen -l -f "$ssh_key_tmp" >/dev/null; then
        rm -f "$ssh_key_tmp"; die "SSH public key did not validate"
    fi
    rm -f "$ssh_key_tmp"
    /usr/sbin/sshd -t || die "existing SSH server configuration is invalid"
    touch "$auth"
    if ! awk -v type="$ssh_type" -v body="$ssh_body" '$1==type && $2==body {found=1} END {exit !found}' "$auth"; then
        # Leading newline also handles an existing final line without a newline.
        printf '\n%s %s\n' "$ssh_type" "$ssh_body" >> "$auth"
    fi
    chown pi:"$group" "$auth"
    chmod 600 "$auth"
    systemctl enable --now ssh.service >&2
    systemctl is-active --quiet ssh.service || die "SSH failed to start"
    systemctl is-enabled --quiet ssh.service || die "SSH is not enabled at boot"

    conf_tmp=$(mktemp "$WG_DIR/.wg-neon-conf.XXXXXX")
    # This file is written on the Pi only; the private key never leaves it.
    {
        printf '%s\n[Interface]\nPrivateKey = ' "$MARKER"
        cat "$KEY"
        printf '\nAddress = %s/32\n\n[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = 10.88.0.0/16\nPersistentKeepalive = 25\n' "$address" "$server_pub" "$endpoint"
    } > "$conf_tmp"
    chmod 600 "$conf_tmp"
    if [ -f "$CONF" ] && cmp -s "$conf_tmp" "$CONF"; then
        rm -f "$conf_tmp"
    else
        # Keep a root-only backup. Preserve the original profile on failed restarts.
        backup=""
        if [ -f "$CONF" ]; then
            backup=$(mktemp "$WG_DIR/.wg-neon-backup.XXXXXX")
            cp -p "$CONF" "$backup"
        fi
        mv "$conf_tmp" "$CONF"
        if ! systemctl restart wg-quick@wg-neon.service >&2; then
            systemctl stop wg-quick@wg-neon.service >&2 || :
            if [ -n "$backup" ]; then
                mv "$backup" "$CONF"
                systemctl start wg-quick@wg-neon.service >&2 || :
            else
                rm -f "$CONF"
            fi
            die "WireGuard startup failed; previous profile restored if present"
        fi
        if [ -n "$backup" ]; then rm -f "$backup"; fi
    fi
    systemctl enable --now wg-quick@wg-neon.service >&2
    systemctl is-active --quiet wg-quick@wg-neon.service || die "WireGuard is inactive"
    systemctl is-enabled --quiet wg-quick@wg-neon.service || die "WireGuard is not enabled at boot"
    # A real response is required; a running service alone proves no connectivity.
    attempt=0
    while :; do
        ping -c 1 -W 2 10.88.0.1 >/dev/null 2>&1 || :
        handshakes=$(wg show "$INTERFACE" latest-handshakes) || die "cannot check WireGuard"
        now=$(date +%s)
        if printf '%s\n' "$handshakes" | awk -v key="$server_pub" -v now="$now" '$1==key && $2>0 && $2>=now-180 && $2<=now+30 {ok=1} END {exit !ok}'; then
            break
        fi
        attempt=$((attempt + 1))
        [ "$attempt" -lt 10 ] || die "no handshake with Neon; profile retained for retry (check outbound UDP 51820)"
        sleep 2
    done
    log "WireGuard handshake verified; SSH and WireGuard enabled at boot"
    ;;
status)
    [ "$#" = 0 ] || die "status takes no arguments"
    [ -f "$CONF" ] || die "not installed"
    if ! systemctl is-active --quiet ssh.service || ! systemctl is-enabled --quiet ssh.service; then
        die "SSH is not active and enabled"
    fi
    if ! systemctl is-active --quiet wg-quick@wg-neon.service || ! systemctl is-enabled --quiet wg-quick@wg-neon.service; then
        die "WireGuard is not active and enabled"
    fi
    wg show "$INTERFACE" latest-handshakes
    ;;
esac
