#!/bin/sh

BASE=/var/SaaS/zapret2
. "$BASE/lib.sh"

if [ -r /var/tmp/zapret2-nfqws.pid ]; then
    oldpid=`cat /var/tmp/zapret2-nfqws.pid 2>/dev/null`
    pid_matches "$oldpid" "$BASE/nfqws2" && exit 0
fi

"$BASE/add-rules.sh" || exit 1

exec "$BASE/nfqws2" \
    --qnum="$QNUM" \
    --pidfile=/var/tmp/zapret2-nfqws.pid \
    --fwmark="$MARK" \
    --lua-init=@"$BASE/zapret-lib.lua" \
    --lua-init=@"$BASE/zapret-antidpi.lua" \
    --filter-tcp=80,443 --in-range=-s1 \
      --lua-desync=oob:urp=0 \
    --new \
    --filter-udp=443 --filter-l7=quic --out-range=-d5 --in-range=-d3 \
      --payload=quic_initial \
      --lua-desync=fake:blob=fake_default_quic:repeats=6
