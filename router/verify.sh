#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006
BASE=${Z2_BASE:-/var/SaaS/zapret2}
# shellcheck source=lib.sh
. "$BASE/lib.sh" || exit 1
fail() { echo "VERIFY FAILED: $*" >&2; exit 1; }
for f in nfqws2 g84-lock run.sh watch-rules.sh add-rules.sh del-rules.sh; do
    [ -x "$BASE/$f" ] || fail "missing executable $f"
done
for f in VERSION config hosts.txt hosts-exclude.txt zapret-lib.lua zapret-antidpi.lua zapret-auto.lua g84-auto.lua; do
    [ -r "$BASE/$f" ] || fail "missing file $f"
done
npid=`cat "$TMP/zapret2-nfqws.pid" 2>/dev/null` || fail 'missing nfqws PID file'
pid_matches "$npid" "$BASE/nfqws2" || fail 'nfqws process is missing or unrelated'
wpid=`cat "$TMP/zapret2-watch.pid" 2>/dev/null` || fail 'missing watcher PID file'
pid_matches "$wpid" "$BASE/watch-rules.sh" || fail 'watcher process is missing or unrelated'
awk -v q="$QNUM" -v p="$npid" '$1==q && $2==p {found=1} END {exit !found}' "$PROC/net/netfilter/nfnetlink_queue" || fail 'NFQUEUE has no matching handler'
rule() { "$TABLE" -t mangle -C "$@" 2>/dev/null || fail "$TABLE rule: $*"; }
link() {
    rule "$@"
    chain=$1; shift
    # Match the jump and interface, allowing iptables's normalized flag ordering.
    lines=`"$TABLE" -t mangle -S "$chain"` || fail "$TABLE chain $chain"
    count=`printf '%s\n' "$lines" | awk -v c="$chain" -v wan="$WAN" -v dst="$4" '
      $1=="-A" && $2==c {iface=0; jump=0; for(i=3;i<=NF;i++){if(($i=="-i"||$i=="-o")&&$(i+1)==wan)iface=1; if($i=="-j"&&$(i+1)==dst)jump=1} if(iface&&jump)n++} END{print n+0}'`
    [ "$count" = 1 ] || fail "$TABLE duplicate/missing jump $chain"
}
verify_family() {
    TABLE=$1
    project_rules || return 1
    for entry in 'Z2OUT 2' 'Z2IN 4'; do
        # Fixed internal pairs intentionally split into positional arguments.
        # shellcheck disable=SC2086
        set -- $entry
        lines=`"$TABLE" -t mangle -S "$1"` || fail "$TABLE missing chain $1"
        count=`printf '%s\n' "$lines" | awk '$1=="-A" {n++} END {print n+0}'`
        [ "$count" = "$2" ] || fail "$TABLE unexpected rules in $1"
    done
}
verify_family iptables || exit 1
if [ "$ENABLE_IPV6" = 1 ]; then
    ip6tables --version >/dev/null 2>&1 || fail 'IPv6 enabled but ip6tables unavailable'
    verify_family ip6tables || exit 1
fi
echo 'Service structure verified; reachability and reboot persistence are separate checks.'
