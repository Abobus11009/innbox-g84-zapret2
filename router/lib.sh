#!/bin/sh

BASE=/var/SaaS/zapret2
CONFIG=$BASE/config
[ -r "$CONFIG" ] && . "$CONFIG"

WAN=${WAN:-nas1}
QNUM=${QNUM:-200}
MARK=${MARK:-0x40000000}
ENABLE_IPV6=${ENABLE_IPV6:-1}
LOCK=/var/tmp/zapret2-rules.lock

pid_matches() {
    pid=$1
    needle=$2
    [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
    tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null | grep -q "$needle"
}

stop_pidfile() {
    file=$1
    needle=$2
    [ -r "$file" ] || return 0
    pid=`cat "$file" 2>/dev/null`
    if pid_matches "$pid" "$needle"; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$file"
}

acquire_rules_lock() {
    tries=0
    while ! mkdir "$LOCK" 2>/dev/null; do
        owner=`cat "$LOCK/pid" 2>/dev/null`
        if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
            rm -f "$LOCK/pid" 2>/dev/null
            rmdir "$LOCK" 2>/dev/null
            continue
        fi
        tries=`expr "$tries" + 1`
        [ "$tries" -lt 10 ] || return 1
        sleep 1
    done
    echo $$ > "$LOCK/pid"
    trap 'rm -f "$LOCK/pid" 2>/dev/null; rmdir "$LOCK" 2>/dev/null' 0 1 2 15
}
