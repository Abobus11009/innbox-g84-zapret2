#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006

BASE=${Z2_BASE:-/var/SaaS/zapret2}
# shellcheck source=lib.sh
. "$BASE/lib.sh" || exit 1

appmgrcmd stop zapret2 2>/dev/null || true
appmgrcmd stop zapret2-rules 2>/dev/null || true
stop_pidfile "$TMP/zapret2-watch.pid" "$BASE/watch-rules.sh" || exit 1
stop_pidfile "$TMP/zapret2-nfqws.pid" "$BASE/nfqws2" || exit 1
sleep 1
"$BASE/del-rules.sh" || exit 1
