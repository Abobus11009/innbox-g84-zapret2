#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006

BASE=${Z2_BASE:-/var/SaaS/zapret2}
TMP=${Z2_TMP:-/var/tmp}
PROC=${Z2_PROC:-/proc}
# shellcheck source=config
if [ -r "$BASE/config" ]; then . "$BASE/config" || exit 1; fi
WAN=${WAN:-nas1}
QNUM=${QNUM:-200}
MARK=${MARK:-0x40000000}
ENABLE_IPV6=${ENABLE_IPV6:-1}
LOCK=$TMP/zapret2-rules.flock

pid_matches() (
    [ -n "$1" ] && [ -r "$PROC/$1/cmdline" ] || exit 1
    first=`tr '\000' '\n' < "$PROC/$1/cmdline" | sed -n '1p'`
    second=`tr '\000' '\n' < "$PROC/$1/cmdline" | sed -n '2p'`
    [ "$first" = "$2" ] && exit 0
    case "$first" in
        */ash|*/sh) [ "$second" = "$2" ] ;;
        *) exit 1 ;;
    esac
)

owned_pids() (
    # Prefilter in one grep process; exact argv checks still decide ownership.
    # Scanning every kernel thread with separate tr/sed processes is slow on G84.
    candidates=`grep -l -F "$1" "$PROC"/[0-9]*/cmdline 2>/dev/null` || :
    for f in $candidates; do
        [ -r "$f" ] || continue
        p=${f%/cmdline}; p=${p##*/}
        if pid_matches "$p" "$1"; then echo "$p"; fi
    done
)

stop_pidfile() (
    [ -r "$1" ] || exit 0
    p=`cat "$1"` || exit 1
    if pid_matches "$p" "$2"; then
        kill "$p" || exit 1
        n=0
        while pid_matches "$p" "$2"; do
            n=`expr "$n" + 1`
            if [ "$n" = 10 ]; then
                # Legacy watcher traps TERM without exiting; kill only this exact owner.
                pid_matches "$p" "$2" && kill -9 "$p" || exit 1
            fi
            [ "$n" -lt 13 ] || { echo "process did not stop: $p" >&2; exit 1; }
            sleep 1
        done
    elif [ -r "$PROC/$p/cmdline" ]; then
        echo "PID file belongs to another process: $1" >&2
        exit 1
    fi
    rm -f "$1"
)

# Used only by add-rules.sh/del-rules.sh, not by the packet handler.
# The kernel lock file is permanent until reboot and must never be removed.
lock_rules() {
    if [ "${1:-}" != --locked ]; then
        exec "$BASE/g84-lock" "$LOCK" 10 "${Z2_SHELL:-/bin/ash}" "$0" --locked
    fi
}

# One definition of every project rule: both application and verification use it.
project_rules() {
    rule Z2OUT -p tcp -m multiport --dports 80,443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2OUT -p udp --dport 443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags SYN,ACK SYN,ACK -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags RST RST -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags FIN FIN -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p udp --sport 443 -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    link POSTROUTING -o "$WAN" -j Z2OUT || return 1
    link FORWARD -i "$WAN" -j Z2IN || return 1
    link INPUT -i "$WAN" -j Z2IN || return 1
}
