#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006

BASE=${Z2_BASE:-/var/SaaS/zapret2}
# shellcheck source=lib.sh
. "$BASE/lib.sh" || exit 1

if [ -r "$TMP/zapret2-watch.pid" ]; then
    oldpid=`cat "$TMP/zapret2-watch.pid" 2>/dev/null`
    pid_matches "$oldpid" "$BASE/watch-rules.sh" && exit 0
fi

echo $$ > "$TMP/zapret2-watch.pid" || exit 1
trap 'rm -f "$TMP/zapret2-watch.pid"' 0
trap 'exit 0' 1 2 15

while true; do
    sleep 15
    "$BASE/add-rules.sh" || echo "firewall repair failed" >&2
done
