#!/bin/sh

BASE=/var/SaaS/zapret2
. "$BASE/lib.sh"

appmgrcmd stop zapret2 2>/dev/null || true
appmgrcmd stop zapret2-rules 2>/dev/null || true
stop_pidfile /var/tmp/zapret2-watch.pid "$BASE/watch-rules.sh"
stop_pidfile /var/tmp/zapret2-nfqws.pid "$BASE/nfqws2"
sleep 1
"$BASE/del-rules.sh" 2>/dev/null || true
exit 0
