#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006
# Run the staged copy: all errors are explicit, including inside conditionals.
BASE=${Z2_BASE:-/var/SaaS/zapret2}
TMP=${Z2_TMP:-/var/tmp}
PROC=${Z2_PROC:-/proc}
STAGE=${Z2_STAGE:-$TMP/zapret2-install/zapret2}
JOURNAL=$BASE.transaction
NEXT=$BASE.new
OLD=$BASE.old
FAILED=$BASE.failed
umask 077
FIELDS='name path argument auto_start crash_start'
SELF_DIR=${0%/*}
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh" || exit 1

write_state() { printf '%s\n' "$2" > "$JOURNAL/$1"; }
read_state() { cat "$JOURNAL/$1"; }

save_slot() {
    slot=$1; expected=$2
    mkdir "$JOURNAL/slot-$slot" || return 1
    # A vacant slot has no name; do not infer that other read failures are vacancy.
    name=`csmconf -g "/appmgr:$slot/name" 2>/dev/null` || return 1
    if [ -z "$name" ]; then
        : > "$JOURNAL/slot-$slot/vacant" || return 1
        return 0
    fi
    [ "$name" = "$expected" ] || { echo "slot $slot is not owned by $expected" >&2; return 1; }
    for field in $FIELDS; do
        if value=`csmconf -g "/appmgr:$slot/$field" 2>/dev/null`; then
            printf '%s' "$value" > "$JOURNAL/slot-$slot/$field" || return 1
        else
            # Refuse ambiguous reads of a populated slot. Never guess an old value.
            echo "cannot snapshot /appmgr:$slot/$field" >&2
            return 1
        fi
    done
    case "$expected" in zapret2) expected_path=$BASE/run.sh ;; *) expected_path=$BASE/watch-rules.sh ;; esac
    [ "`cat "$JOURNAL/slot-$slot/path"`" = "$expected_path" ] || return 1
}

restore_slot() {
    slot=$1
    if [ -f "$JOURNAL/slot-$slot/vacant" ]; then
        name=`csmconf -g "/appmgr:$slot/name" 2>/dev/null` || return 1
        if [ -n "$name" ]; then
            case "$name" in zapret2|zapret2-rules) ;; *) echo 'rollback refuses foreign appmgr slot' >&2; return 1 ;; esac
            csmconf -d "/appmgr:$slot" || return 1
            name=`csmconf -g "/appmgr:$slot/name"` || return 1
            [ -z "$name" ] || return 1
        fi
    else
        for field in $FIELDS; do
            value=`cat "$JOURNAL/slot-$slot/$field"` || return 1
            csmconf -s "/appmgr:$slot/$field" "$value" || return 1
            actual=`csmconf -g "/appmgr:$slot/$field"` || return 1
            [ "$actual" = "$value" ] || return 1
        done
    fi
}

set_key() {
    csmconf -s "$1" "$2" || return 1
    actual=`csmconf -g "$1"` || return 1
    [ "$actual" = "$2" ] || { echo "appmgr read-back mismatch: $1" >&2; return 1; }
}

register_slot() {
    slot=$1; name=$2; path=$3
    set_key "/appmgr:$slot/name" "$name" &&
    set_key "/appmgr:$slot/path" "$path" &&
    set_key "/appmgr:$slot/argument" start &&
    set_key "/appmgr:$slot/auto_start" 1 &&
    set_key "/appmgr:$slot/crash_start" 1
}

stop_services() {
    # appmgrcmd may return nonzero after a successful IPC request on this firmware.
    # Verify actual process termination instead of trusting that return code.
    appmgrcmd stop zapret2-rules 2>/dev/null || true
    appmgrcmd stop zapret2 2>/dev/null || true
    for file in "$TMP/zapret2-watch.pid:$BASE/watch-rules.sh" "$TMP/zapret2-nfqws.pid:$BASE/nfqws2"; do
        stop_pidfile "${file%%:*}" "${file#*:}" || return 1
    done
    # Legacy installations may have no watcher PID file.
    for path in "$BASE/nfqws2" "$BASE/watch-rules.sh" "$BASE/add-rules.sh" "$BASE/del-rules.sh" "$BASE/g84-lock"; do
        pids=`owned_pids "$path"` || return 1
        for p in $pids; do kill "$p" 2>/dev/null || return 1; done
        n=0
        while [ -n "`owned_pids "$path"`" ]; do
            n=`expr "$n" + 1`
            if [ "$n" = 10 ]; then
                for p in `owned_pids "$path"`; do pid_matches "$p" "$path" && kill -9 "$p" || return 1; done
            fi
            [ "$n" -lt 13 ] || return 1
            sleep 1
        done
    done
}

start_one() {
    name=$1; path=$2; argument=${3:-start}; restart=${4:-1}
    case "$name" in zapret2) process=$BASE/nfqws2 ;; *) process=$path ;; esac
    appmgrcmd add "$name" "$path" "$argument" "$restart" 2>/dev/null || true
    n=0
    while [ -z "`owned_pids "$process"`" ]; do
        n=`expr "$n" + 1`
        if [ "$n" = 3 ]; then
            # Firmware IPC can be unavailable until reboot. Registration is saved;
            # directly launch this owned script and still require a matching process.
            echo "appmgr live start unavailable; launching $name directly" >&2
            case "$name" in zapret2) log=$TMP/zapret2.log ;; *) log=$TMP/zapret2-rules.log ;; esac
            "${Z2_SHELL:-/bin/ash}" "$path" "$argument" </dev/null >"$log" 2>&1 &
        fi
        [ "$n" -lt 10 ] || { echo "service failed to start: $name" >&2; return 1; }
        sleep 1
    done
}

rollback() {
    if [ -r "$JOURNAL/result" ] && [ "`read_state result`" = rolled-back ]; then return 0; fi
    echo 'Restoring previous installation and owned appmgr settings...' >&2
    nfq_slot=`read_state nfq-slot` || return 1
    watch_slot=`read_state watch-slot` || return 1
    if [ -f "$JOURNAL/stop-started" ]; then
        stop_services || return 1
        if [ -f "$JOURNAL/switch-started" ] && { [ -d "$OLD" ] || [ ! -f "$JOURNAL/had-installation" ]; }; then
            # If the first rename succeeded and the second failed, BASE is absent.
            if [ -d "$BASE" ]; then
                "$BASE/del-rules.sh" || return 1
                [ ! -e "$FAILED" ] || return 1
                mv "$BASE" "$FAILED" || return 1
            fi
            if [ -d "$OLD" ]; then mv "$OLD" "$BASE" || return 1; fi
        fi
    fi
    if [ -f "$JOURNAL/register-started" ]; then
        restore_slot "$nfq_slot" && restore_slot "$watch_slot" && csmctl savecfg || return 1
    fi
    if [ -f "$JOURNAL/stop-started" ] && [ -f "$JOURNAL/had-installation" ]; then
        if [ -f "$JOURNAL/nfq-running" ]; then
            argument=`cat "$JOURNAL/slot-$nfq_slot/argument" 2>/dev/null` || argument=start
            restart=`cat "$JOURNAL/slot-$nfq_slot/crash_start" 2>/dev/null` || restart=1
            start_one zapret2 "$BASE/run.sh" "$argument" "$restart" || return 1
            [ -n "`owned_pids "$BASE/nfqws2"`" ] || return 1
        fi
        if [ -f "$JOURNAL/watch-running" ]; then
            argument=`cat "$JOURNAL/slot-$watch_slot/argument" 2>/dev/null` || argument=start
            restart=`cat "$JOURNAL/slot-$watch_slot/crash_start" 2>/dev/null` || restart=1
            start_one zapret2-rules "$BASE/watch-rules.sh" "$argument" "$restart" || return 1
        fi
    fi
    if [ -f "$JOURNAL/stop-started" ] && [ -f "$JOURNAL/had-installation" ] && [ -f "$JOURNAL/rules-present" ]; then
        "$BASE/add-rules.sh" || return 1
    fi
    write_state result rolled-back || return 1
    echo 'Rollback completed. Recovery journal and failed files are retained.' >&2
}

abort_transaction() {
    trap - 0 1 2 15
    if [ -f "$JOURNAL/snapshot-complete" ]; then
        if ! rollback; then
            echo "ROLLBACK FAILED: preserve $JOURNAL, $OLD and $FAILED; run recover after diagnosis" >&2
            exit 52
        fi
    else
        echo "Preparation failed before service changes; preserve $JOURNAL and $NEXT" >&2
    fi
    exit 51
}

recover() {
    [ -r "$JOURNAL/snapshot-complete" ] || { echo 'no complete recovery journal' >&2; return 1; }
    rollback
}

install() {
    wan=$1; ipv6=$2; nfq_slot=$3; watch_slot=$4; version=$5; replace_wan=${6:-0}
    case "$wan" in ''|*[!a-zA-Z0-9_.:-]*) echo 'invalid WAN' >&2; return 1 ;; esac
    case "$ipv6" in 0|1) ;; *) return 1 ;; esac
    case "$replace_wan" in 0|1) ;; *) return 1 ;; esac
    case "$nfq_slot:$watch_slot" in *[!0-9:]*|:*) return 1 ;; esac
    [ "$nfq_slot" -ge 1 ] && [ "$nfq_slot" -le 16 ] && [ "$watch_slot" -ge 1 ] && [ "$watch_slot" -le 16 ] && [ "$nfq_slot" != "$watch_slot" ] || return 1
    for occupied in "$JOURNAL" "$NEXT" "$OLD" "$FAILED"; do
        [ ! -e "$occupied" ] || { echo "recovery data already exists: $occupied" >&2; return 1; }
    done
    mkdir "$JOURNAL" || return 1
    chmod 700 "$JOURNAL" || return 1
    trap abort_transaction 0 1 2 15
    cp "$STAGE/install-transaction.sh" "$JOURNAL/recover.sh" && cp "$STAGE/lib.sh" "$JOURNAL/lib.sh" || return 1
    write_state nfq-slot "$nfq_slot" && write_state watch-slot "$watch_slot" || return 1
    save_slot "$nfq_slot" zapret2 && save_slot "$watch_slot" zapret2-rules || return 1
    if [ -d "$BASE" ]; then : > "$JOURNAL/had-installation" || return 1; fi
    if [ -n "`owned_pids "$BASE/nfqws2"`" ]; then : > "$JOURNAL/nfq-running" || return 1; fi
    if [ -n "`owned_pids "$BASE/watch-rules.sh"`" ]; then : > "$JOURNAL/watch-running" || return 1; fi
    if iptables -t mangle -C POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null; then
        : > "$JOURNAL/rules-present" || return 1
    fi
    : > "$JOURNAL/snapshot-complete" || return 1
    mkdir "$NEXT" && cp -f "$STAGE"/* "$NEXT/" || return 1
    # nfqws2 drops privileges before reopening hostlists: directory must be traversable.
    chmod 755 "$NEXT" || return 1
    chmod 755 "$NEXT"/*.sh "$NEXT/nfqws2" "$NEXT/g84-lock" || return 1
    chmod 644 "$NEXT"/*.lua "$NEXT"/*.txt "$NEXT/config" "$NEXT/VERSION" || return 1
    if [ -d "$BASE" ]; then
        # These files belong to the user; never replace them with payload defaults.
        for file in config hosts.txt hosts-exclude.txt; do
            [ -r "$BASE/$file" ] || return 1
            cp -pf "$BASE/$file" "$NEXT/$file" || return 1
        done
        if [ "$replace_wan" = 1 ]; then printf '\nWAN=%s\n' "$wan" >> "$NEXT/config" || return 1; fi
        # An unavailable kernel facility cannot be kept enabled. Never enable it
        # over a user's explicit IPv4-only choice merely because it is available.
        if [ "$ipv6" = 0 ] && [ "$ENABLE_IPV6" != 0 ]; then printf '\nENABLE_IPV6=0\n' >> "$NEXT/config" || return 1; fi
    else
        printf 'WAN=%s\nQNUM=200\nMARK=0x40000000\nENABLE_IPV6=%s\nDEBUG_LOG=0\n' "$wan" "$ipv6" > "$NEXT/config" || return 1
    fi
    printf 'NFQWS_SLOT=%s\nWATCH_SLOT=%s\n' "$nfq_slot" "$watch_slot" > "$NEXT/appmgr-slots" || return 1
    [ "`cat "$NEXT/VERSION"`" = "$version" ] || return 1
    Z2_BASE="$NEXT" "$NEXT/run.sh" check || return 1
    # Verify kernel locking before touching services; an unsupported helper fails closed.
    "$NEXT/g84-lock" "$TMP/zapret2-install-probe.flock" 0 "${Z2_SHELL:-/bin/ash}" -c ':' || return 1
    : > "$JOURNAL/stop-started" || return 1
    stop_services || return 1
    if [ -d "$BASE" ]; then "$BASE/del-rules.sh" || return 1; fi
    : > "$JOURNAL/switch-started" || return 1
    if [ -d "$BASE" ]; then mv "$BASE" "$OLD" || return 1; fi
    mv "$NEXT" "$BASE" || return 1
    : > "$JOURNAL/register-started" || return 1
    register_slot "$nfq_slot" zapret2 "$BASE/run.sh" && register_slot "$watch_slot" zapret2-rules "$BASE/watch-rules.sh" && csmctl savecfg || return 1
    start_one zapret2 "$BASE/run.sh" && start_one zapret2-rules "$BASE/watch-rules.sh" || return 1
    "$BASE/verify.sh" || return 1
    write_state result committed || return 1
    trap - 0 1 2 15
    # Keep OLD/journal through the host's optional reboot verification.
    echo 'Installation committed; previous files retained until final verification.'
}

remove_owned_slot() {
    slot=$1; expected=$2
    name=`csmconf -g "/appmgr:$slot/name"` || return 1
    [ -n "$name" ] || return 0
    [ "$name" = "$expected" ] || return 1
    # Clear only fields we snapshot. Deleting the entire node would destroy
    # firmware/user extension fields that cannot be restored by this journal.
    set_key "/appmgr:$slot/auto_start" 0 &&
    set_key "/appmgr:$slot/crash_start" 0 &&
    set_key "/appmgr:$slot/path" '' &&
    set_key "/appmgr:$slot/argument" '' &&
    set_key "/appmgr:$slot/name" ''
}

verify_removed() {
    [ -z "`owned_pids "$BASE/nfqws2"`" ] && [ -z "`owned_pids "$BASE/watch-rules.sh"`" ] || return 1
    for table in iptables ip6tables; do
        if [ "$table" = ip6tables ] && ! ip6tables --version >/dev/null 2>&1; then
            [ "$ENABLE_IPV6" = 0 ] || return 1
            continue
        fi
        rules=`"$table" -t mangle -S` || return 1
        if printf '%s\n' "$rules" | grep -E '(^-[NA] Z2(OUT|IN)( |$)| -j Z2(OUT|IN)( |$))' >/dev/null; then return 1; fi
    done
}

uninstall() {
    nfq_slot=$1; watch_slot=$2
    case "$nfq_slot:$watch_slot" in *[!0-9:]*|:*) return 1 ;; esac
    [ "$nfq_slot" -ge 1 ] && [ "$nfq_slot" -le 16 ] && [ "$watch_slot" -ge 1 ] && [ "$watch_slot" -le 16 ] && [ "$nfq_slot" != "$watch_slot" ] || return 1
    [ -d "$BASE" ] || return 1
    for occupied in "$JOURNAL" "$NEXT" "$OLD" "$FAILED"; do
        [ ! -e "$occupied" ] || { echo "recovery data exists: $occupied" >&2; return 1; }
    done
    mkdir "$JOURNAL" && chmod 700 "$JOURNAL" || return 1
    trap abort_transaction 0 1 2 15
    cp "$SELF_DIR/install-transaction.sh" "$JOURNAL/recover.sh" && cp "$SELF_DIR/lib.sh" "$JOURNAL/lib.sh" || return 1
    write_state nfq-slot "$nfq_slot" && write_state watch-slot "$watch_slot" || return 1
    save_slot "$nfq_slot" zapret2 && save_slot "$watch_slot" zapret2-rules || return 1
    : > "$JOURNAL/had-installation" || return 1
    if [ -n "`owned_pids "$BASE/nfqws2"`" ]; then : > "$JOURNAL/nfq-running" || return 1; fi
    if [ -n "`owned_pids "$BASE/watch-rules.sh"`" ]; then : > "$JOURNAL/watch-running" || return 1; fi
    if iptables -t mangle -C POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null; then : > "$JOURNAL/rules-present" || return 1; fi
    : > "$JOURNAL/snapshot-complete" || return 1
    : > "$JOURNAL/stop-started" || return 1
    stop_services && "$BASE/del-rules.sh" || return 1
    : > "$JOURNAL/register-started" || return 1
    remove_owned_slot "$watch_slot" zapret2-rules && remove_owned_slot "$nfq_slot" zapret2 && csmctl savecfg || return 1
    verify_removed || return 1
    : > "$JOURNAL/switch-started" || return 1
    mv "$BASE" "$OLD" || return 1
    verify_removed || return 1
    write_state result uninstall-committed || return 1
    trap - 0 1 2 15
    echo 'Uninstall committed; old files and journal retained until host cleanup.'
}

case "${1:-}" in
    install) { [ "$#" = 6 ] || [ "$#" = 7 ]; } || exit 64; shift; install "$@" || exit 51 ;;
    uninstall) [ "$#" = 3 ] || exit 64; shift; uninstall "$@" || exit 51 ;;
    recover) recover || exit 52 ;;
    *) echo 'usage: install-transaction.sh install WAN IPV6 NFQ_SLOT WATCH_SLOT VERSION [REPLACE_WAN] | recover' >&2; exit 64 ;;
esac
