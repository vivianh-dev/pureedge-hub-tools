#!/bin/sh
# Runs on the Pi. A trial network sweep; it does not establish or repair
# fixture association, discovery, or lighting commands.
# Usage: sudo sh wiz-keepalive.sh install|remove|status|run
#        sh wiz-keepalive.sh discover

WRAPPER=/usr/local/bin/wiz-keepalive-sweep
CRONFILE=/etc/cron.d/wiz-keepalive
UNITFILE=/etc/systemd/system/wiz-keepalive.service
TIMERFILE=/etc/systemd/system/wiz-keepalive.timer

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

require_root() { [ "$(id -u)" -eq 0 ] || die "use sudo sh $0 $1"; }
using_systemd() { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; }

stagger_minutes() {
    seed=$(cat /etc/machine-id 2>/dev/null || hostname) || return 1
    offset=$(printf '%s' "$seed" | cksum | awk '{print $1 % 10}')
    printf '%s,%s,%s,%s,%s,%s\n' "$offset" "$((offset+10))" "$((offset+20))" "$((offset+30))" "$((offset+40))" "$((offset+50))"
}

# Write new content completely before replacing an installed file.
atomic_write() {
    destination=$1; permissions=$2
    mkdir -p "$(dirname "$destination")" || return 1
    staging=$(mktemp "$destination.XXXXXX") || return 1
    if cat > "$staging" && chmod "$permissions" "$staging" && mv -f "$staging" "$destination"; then
        return 0
    fi
    rm -f "$staging"
    return 1
}

write_wrapper() {
    interface=${WIZ_KEEPALIVE_INTERFACE:-}
    case "$interface" in *[!a-zA-Z0-9_.:-]*) return 1 ;; esac
    {
        printf '#!/bin/sh\nWIZ_KEEPALIVE_INTERFACE=%s\nexport WIZ_KEEPALIVE_INTERFACE\n' "$interface"
        cat <<'SWEEP'
#!/bin/sh
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

[ "$(id -u)" -eq 0 ] || die "the sweep must run as root"
command -v flock >/dev/null 2>&1 || die "flock is unavailable"
exec 9>/run/lock/wiz-keepalive.lock || exit 1

flock -n -E 75 9
lock_rc=$?
[ "$lock_rc" -ne 75 ] || exit 0
[ "$lock_rc" -eq 0 ] || die "cannot acquire the sweep lock"
cidr=$(detect_cidr) || die "cannot detect an IPv4 subnet (/16 through /32)"
if command -v nmap >/dev/null 2>&1; then
    nmap -sn -n -T4 --max-retries 1 --host-timeout 5s "$cidr" >/dev/null
    exit $?
fi
ping_hosts "$cidr" sweep || die "ping sweep failed"
SWEEP
    } | atomic_write "$WRAPPER" 755
}

remove_timer() {
    if [ -f "$UNITFILE" ] || [ -f "$TIMERFILE" ]; then
        if using_systemd; then
            systemctl disable --now wiz-keepalive.timer || return 1
        fi
        rm -f "$UNITFILE" "$TIMERFILE" || return 1
        if using_systemd; then systemctl daemon-reload || return 1; fi
    fi
    return 0
}

cron_running() {
    if using_systemd; then systemctl is-active --quiet cron
    elif command -v service >/dev/null 2>&1; then service cron status >/dev/null 2>&1
    else return 1
    fi
}

install_cron() {
    if using_systemd; then
        systemctl is-enabled --quiet cron || systemctl enable cron || return 1
        cron_running || systemctl start cron || return 1
    else
        cron_running || service cron start || return 1
    fi
    cron_running || return 1
    minutes=$(stagger_minutes) || return 1
    atomic_write "$CRONFILE" 644 <<EOF
$minutes * * * * root $WRAPPER
EOF
}

install_timer() {
    atomic_write "$UNITFILE" 644 <<EOF || return 1
[Unit]
Description=WiZ trial network sweep
[Service]
Type=oneshot
ExecStart=$WRAPPER
EOF
    atomic_write "$TIMERFILE" 644 <<EOF || return 1
[Unit]
Description=WiZ trial sweep every ten minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
RandomizedDelaySec=30s
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload && systemctl enable --now wiz-keepalive.timer &&
        systemctl is-active --quiet wiz-keepalive.timer
}

case "$1" in
    install)
        require_root install
        cidr=$(detect_cidr) || die "cannot detect an IPv4 subnet (/16 through /32)"
        log "subnet $cidr (check this is the fixture LAN)"
        command -v flock >/dev/null 2>&1 || die "flock is required (util-linux)"
        if ! command -v nmap >/dev/null 2>&1; then
            if command -v apt-get >/dev/null 2>&1; then
                log "trying to install nmap"
                DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=0 -o Acquire::http::Timeout=10 -o Acquire::https::Timeout=10 -o DPkg::Lock::Timeout=10 install -y -qq nmap || log "nmap installation failed; checking ping fallback"
            fi
            command -v nmap >/dev/null 2>&1 || command -v ping >/dev/null 2>&1 || die "nmap and ping are both unavailable"
        fi
        write_wrapper || die "cannot write $WRAPPER"
        if command -v cron >/dev/null 2>&1 || command -v crontab >/dev/null 2>&1; then
            install_cron || die "cron installation/startup failed; no successful installation"
            remove_timer || die "cannot remove the previous timer"
            log "installed: every ten minutes via cron"
        elif using_systemd; then
            install_timer || die "timer installation/startup failed"
            rm -f "$CRONFILE" || die "cannot remove the previous cron entry"
            log "installed: approximately every ten minutes via systemd"
        else
            die "cron or a running systemd is required"
        fi
        ;;
    remove)
        require_root remove
        remove_timer || die "cannot stop/remove the timer"
        rm -f "$CRONFILE" "$WRAPPER" || die "cannot remove installed files"
        log "removed (an already running sweep may finish)"
        ;;
    status)
        healthy=0
        if [ -f "$CRONFILE" ] && [ -f "$TIMERFILE" ]; then
            log "error: both schedulers are configured"; healthy=1
        elif [ -f "$CRONFILE" ]; then
            log "scheduler: cron"; cat "$CRONFILE"
            cron_running || { log "cron is not running"; healthy=1; }
        elif [ -f "$TIMERFILE" ]; then
            log "scheduler: systemd timer"
            if using_systemd; then
                systemctl is-active --quiet wiz-keepalive.timer || { log "timer is not running"; healthy=1; }
            else healthy=1
            fi
        else
            log "not installed"; healthy=1
        fi
        [ -x "$WRAPPER" ] || { log "sweep script is missing"; healthy=1; }
        saved_interface=""
        if [ -f "$WRAPPER" ]; then
            saved_interface=$(awk -F= '/^WIZ_KEEPALIVE_INTERFACE=/{print $2; exit}' "$WRAPPER")
        fi
        cidr=$(WIZ_KEEPALIVE_INTERFACE="$saved_interface" detect_cidr) || { cidr=unknown; healthy=1; }
        log "subnet $cidr"
        if command -v nmap >/dev/null 2>&1; then log "method: nmap"
        elif command -v ping >/dev/null 2>&1; then log "method: ping"
        else log "no scan tool available"; healthy=1
        fi
        exit "$healthy"
        ;;
    run)
        require_root run
        [ -x "$WRAPPER" ] || die "install the sweep first"
        "$WRAPPER" || die "sweep failed"
        ;;
    discover) discover; exit $? ;;
    *) die "usage: sudo sh $0 install|remove|status|run; sh $0 discover" ;;
esac
