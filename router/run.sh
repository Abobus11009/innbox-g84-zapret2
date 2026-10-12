#!/bin/ash

BASE=/var/SaaS/zapret2
. "$BASE/lib.sh"

if [ -r /var/tmp/zapret2-nfqws.pid ]; then
    oldpid=`cat /var/tmp/zapret2-nfqws.pid 2>/dev/null`
    pid_matches "$oldpid" "$BASE/nfqws2" && exit 0
fi

"$BASE/add-rules.sh" || exit 1

set --
if [ "${DEBUG_LOG:-0}" = 1 ]; then
    set -- --debug=@/var/tmp/zapret2-debug.log
fi

exec "$BASE/nfqws2" \
    "$@" \
    --qnum="$QNUM" \
    --pidfile=/var/tmp/zapret2-nfqws.pid \
    --fwmark="$MARK" \
    --lua-init=@"$BASE/zapret-lib.lua" \
    --lua-init=@"$BASE/zapret-antidpi.lua" \
    --lua-init=@"$BASE/zapret-auto.lua" \
    --lua-init=@"$BASE/g84-auto.lua" \
    --filter-tcp=443 --filter-l7=tls \
      --hostlist="$BASE/hosts.txt" --hostlist-exclude="$BASE/hosts-exclude.txt" \
      --out-range=-s17844 --in-range=-s5556 \
      --lua-desync=g84_circular:fails=2:time=120:retrans=2:maxseq=16384:no_http_redirect:hostkey=g84_hostkey:success_detector=g84_success_detector:failure_detector=g84_failure_detector \
      --in-range=x --payload=tls_client_hello \
      --lua-desync=multidisorder:pos=1,midsld:seqovl=568:strategy=1 \
      --lua-desync=multidisorder:pos=1,midsld:seqovl=681:strategy=2 \
      --lua-desync=fake:blob=fake_default_tls:tcp_ack=-66000:repeats=6:strategy=3 \
      --lua-desync=multidisorder:pos=1,midsld:seqovl=568:strategy=3 \
    --new \
    --filter-tcp=80 --filter-l7=http \
      --hostlist="$BASE/hosts.txt" --hostlist-exclude="$BASE/hosts-exclude.txt" \
      --out-range=-s17844 --in-range=-s5556 \
      --lua-desync=g84_circular:fails=2:time=120:retrans=2:maxseq=16384:no_http_redirect:hostkey=g84_hostkey:success_detector=g84_success_detector:failure_detector=g84_failure_detector \
      --in-range=x --payload=http_req \
      --lua-desync=multisplit:pos=method+2,midsld:strategy=1 \
      --lua-desync=http_domcase:strategy=2 \
      --lua-desync=multidisorder:pos=method+2,midsld:strategy=3 \
    --new \
    --filter-udp=443 --filter-l7=quic \
      --hostlist="$BASE/hosts.txt" --hostlist-exclude="$BASE/hosts-exclude.txt" \
      --out-range=-d12 --in-range=-d6 \
      --lua-desync=g84_circular:fails=2:time=120:udp_out=6:udp_in=0:hostkey=g84_hostkey \
      --in-range=x --payload=quic_initial \
      --lua-desync=fake:blob=fake_default_quic:repeats=6:strategy=1 \
      --lua-desync=fake:blob=fake_default_quic:repeats=2:strategy=2 \
      --lua-desync=fake:blob=fake_default_quic:ip_autottl=-1,3-20:ip6_autottl=-1,3-20:repeats=6:strategy=3
