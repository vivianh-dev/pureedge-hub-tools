#!/bin/sh
# Run on a Linux or macOS laptop; the sweep is installed on the Pi.
die() { echo "wiz-keepalive: $*" >&2; exit 1; }
log() { echo "wiz-keepalive: $*"; }

# Validate and normalize IPv4 CIDRs. Limit a sweep to at most 65,536
# addresses; fail explicitly rather than silently truncating a larger LAN.
ipv4_range() {
    awk -v cidr="$1" -v mode="$2" '
    function ip(n, a,b,c,d) {
        a=int(n/16777216); b=int(n/65536)%256; c=int(n/256)%256; d=n%256
        return sprintf("%d.%d.%d.%d",a,b,c,d)
    }
    BEGIN {
        if (split(cidr,p,"/") != 2 || p[2] !~ /^[0-9]+$/ || p[2]<16 || p[2]>32)
            exit 1
        if (split(p[1],o,".") != 4) exit 1
        n=0
        for(i=1;i<=4;i++) {
            if(o[i] !~ /^[0-9]+$/ || o[i]>255) exit 1
            n=n*256+o[i]
        }
        size=2^(32-p[2]); base=int(n/size)*size
        if(mode=="cidr") { print ip(base) "/" (p[2]+0); exit }
        first=base+(size>2); last=base+size-1-(size>2)
        for(n=first;n<=last;n++) print ip(n)
    }'
}

linux_cidr() {
    dev=${WIZ_KEEPALIVE_INTERFACE:-}
    if [ -z "$dev" ]; then
        dev=$(ip -4 route show default 2>/dev/null |
            awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    fi
    if [ -z "$dev" ]; then
        dev=$(ip -o -4 addr show scope global 2>/dev/null |
            awk '$2 !~ /^(lo|wg|tun|tap)/ {sub(/@.*/,"",$2); print $2; exit}')
    fi
    [ -n "$dev" ] || return 1
    addr=$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null |
        awk '$3=="inet" {print $4; exit}')
    ipv4_range "$addr" cidr
}

macos_cidr() {
    dev=${WIZ_KEEPALIVE_INTERFACE:-}
    if [ -z "$dev" ]; then
        dev=$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')
    fi
    [ -n "$dev" ] || return 1
    info=$(ifconfig "$dev" 2>/dev/null | awk '/inet / {
        for(i=1;i<=NF;i++) if($i=="netmask") {print $2, $(i+1); exit}}')
    addr=${info%% *}; mask=${info#* }
    # BSD ifconfig normally prints a hexadecimal mask. Count its one bits,
    # rejecting noncontiguous masks instead of guessing /24.
    prefix=$(awk -v mask="$mask" '
        BEGIN {
            if(mask ~ /^0x/) {
                sub(/^0x/,"",mask); mask=tolower(mask)
                if(length(mask)!=8) exit 1
                for(i=1;i<=8;i++) {
                    v=index("0123456789abcdef",substr(mask,i,1))-1
                    if(v<0) exit 1
                    for(b=8;b>=1;b/=2) {
                        bit=int(v/b); v%=b
                        if(bit) {if(zero) exit 1; ones++} else zero=1
                    }
                }
            } else {
                if(split(mask,o,".")!=4) exit 1
                for(i=1;i<=4;i++) {
                    if(o[i] !~ /^[0-9]+$/ || o[i]>255) exit 1
                    v=o[i]+0
                    for(b=128;b>=1;b/=2) {
                        bit=int(v/b); v%=b
                        if(bit) {if(zero) exit 1; ones++} else zero=1
                    }
                }
            }
            print ones+0
        }') || return 1
    ipv4_range "$addr/$prefix" cidr
}

detect_cidr() {
    case "$(uname -s)" in
        Linux) linux_cidr ;;
        Darwin) macos_cidr ;;
        *) return 1 ;;
    esac
}

# Exit 1 from ping means no reply, not a broken scan. Other failures must
# reach the caller. Limit concurrency to 16 probes on every platform.
wait_probes() {
    failed=0
    for pid in $pids; do
        wait "$pid"
        probe_rc=$?
        [ "$probe_rc" -le 1 ] || failed=1
    done
    [ "$failed" -eq 0 ]
}

ping_hosts() {
    command -v ping >/dev/null 2>&1 || { echo "ping is unavailable" >&2; return 1; }
    hosts=$(ipv4_range "$1" hosts) || return 1
    pids=""; count=0; scan_failed=0
    platform=$(uname -s)
    for target in $hosts; do
        (
            if [ "$platform" = Darwin ]; then
                ping -c 1 -t 1 "$target" >/dev/null 2>&1
            else
                ping -c 1 -W 1 "$target" >/dev/null 2>&1
            fi
            probe_rc=$?
            if [ "$probe_rc" -eq 0 ] && [ "$2" = discover ]; then echo "$target"; fi
            exit "$probe_rc"
        ) &
        pids="$pids $!"; count=$((count + 1))
        if [ "$count" -eq 16 ]; then
            wait_probes || scan_failed=1
            pids=""; count=0
        fi
    done
    wait_probes || scan_failed=1
    [ "$scan_failed" -eq 0 ]
}

discover() {
    cidr=$(detect_cidr) || { echo "cannot detect an IPv4 subnet (/16 through /32)" >&2; return 1; }
    log "scanning $cidr for candidate hubs"
    discovery_file=$(mktemp) || return 1
    if command -v nmap >/dev/null 2>&1; then
        if ! nmap -sn -n -T4 --host-timeout 5s "$cidr" > "$discovery_file"; then
            rm -f "$discovery_file"
            echo "nmap discovery failed" >&2
            return 1
        fi
        found_hosts=$(awk '/^Nmap scan report for /{print $NF}' "$discovery_file")
    else
        if ! ping_hosts "$cidr" discover > "$discovery_file"; then
            rm -f "$discovery_file"
            echo "ping discovery failed" >&2
            return 1
        fi
        found_hosts=$(cat "$discovery_file")
    fi
    rm -f "$discovery_file"
    for candidate in $found_hosts; do
        ports=""
        if command -v nc >/dev/null 2>&1; then
            for port in 22 80 443; do
                if [ "$(uname -s)" = Darwin ]; then
                    nc -z -G 1 -w 1 "$candidate" "$port" >/dev/null 2>&1 && ports="$ports $port"
                else
                    nc -z -w 1 "$candidate" "$port" >/dev/null 2>&1 && ports="$ports $port"
                fi
            done
            echo "$candidate  open ports:${ports:- none} (candidate only)"
        else
            echo "$candidate  responding host (nc unavailable; ports unchecked)"
        fi
    done
    return 0
}

PAYLOAD_URL=https://raw.githubusercontent.com/vivianh-dev/pureedge-hub-tools/main/wiz-keepalive.sh
downloaded=""
# Invoked by the exit trap.
# shellcheck disable=SC2329
cleanup() { if [ -n "$downloaded" ]; then rm -f "$downloaded"; fi; }
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mode=${1:-}
if [ -z "$mode" ]; then
    printf 'install, remove, status, run or discover? (install) ' > /dev/tty 2>/dev/null || die "supply an action and hub address"
    read -r mode < /dev/tty || die "cannot read action; supply it as an argument"
    mode=${mode:-install}
else
    shift
fi
case "$mode" in
    install|remove|status|run) ;;
    discover) discover; exit $? ;;
    *) die "unknown action: $mode" ;;
esac

if [ $# -eq 0 ]; then
    printf 'hub IP address(es), space separated: ' > /dev/tty 2>/dev/null || die "supply a hub address"
    read -r hubs < /dev/tty || die "cannot read addresses; supply them as arguments"
    set -f
    # Split space-separated answers; pathname expansion is disabled above.
    # shellcheck disable=SC2086
    set -- $hubs
    set +f
fi
[ $# -gt 0 ] || die "no hub address given"
for hub in "$@"; do
    case "$hub" in
        ''|-*|*[!a-zA-Z0-9._-]*) die "invalid IPv4 address or hostname: $hub" ;;
    esac
done
command -v ssh >/dev/null 2>&1 || die "OpenSSH ssh is required"

# A sidecar is used only when explicitly selected. Piped invocations always
# download the published payload unless WIZ_KEEPALIVE_PAYLOAD is set.
if [ -n "${WIZ_KEEPALIVE_PAYLOAD:-}" ]; then
    payload=$WIZ_KEEPALIVE_PAYLOAD
else
    command -v curl >/dev/null 2>&1 || die "curl is required to download the payload"
    downloaded=$(mktemp) || die "cannot create a payload file"
    payload=$downloaded
    curl -fsSL --connect-timeout 10 --max-time 60 "$PAYLOAD_URL" -o "$payload" || die "payload download failed"
fi
[ -s "$payload" ] || die "payload is empty or unreadable"
sh -n "$payload" || die "payload has invalid shell syntax"

failed=0
for hub in "$@"; do
    log "$hub: $mode"
    # Keep a failed payload for the operator's printed retry command. Use
    # a unique path so concurrent installers cannot overwrite one another.
    # Dollar expressions must be expanded on the remote hub.
    # shellcheck disable=SC2016
    remote='remote_file=$(mktemp /tmp/wiz-keepalive.XXXXXX) || exit 1
if ! cat > "$remote_file"; then rm -f "$remote_file"; exit 1; fi
sudo -n sh "$remote_file" MODE
rc=$?
if [ "$rc" -eq 0 ]; then
    rm -f "$remote_file"
else
    printf "Retry on the hub: sudo sh %s MODE\n" "$remote_file" >&2
fi
exit "$rc"'
    # mode has already been restricted to four literal action names.
    remote=$(printf '%s' "$remote" | sed "s/MODE/$mode/g")
    if ssh -o ConnectTimeout=10 "pi@$hub" "$remote" < "$payload"; then
        log "$hub: succeeded"
    else
        log "$hub: failed (check the error above)"
        failed=1
    fi
done
exit "$failed"
