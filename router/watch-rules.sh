#!/bin/sh

BASE=/var/SaaS/zapret2
. "$BASE/lib.sh"

if [ -r /var/tmp/zapret2-watch.pid ]; then
    oldpid=`cat /var/tmp/zapret2-watch.pid 2>/dev/null`
    pid_matches "$oldpid" "$BASE/watch-rules.sh" && exit 0
fi

echo $$ > /var/tmp/zapret2-watch.pid
trap 'rm -f /var/tmp/zapret2-watch.pid' 0 1 2 15

while true; do
    sleep 15
    "$BASE/add-rules.sh"
done
