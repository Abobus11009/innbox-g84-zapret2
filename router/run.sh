#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006

BASE=${Z2_BASE:-/var/SaaS/zapret2}
# shellcheck source=lib.sh
. "$BASE/lib.sh" || exit 1
CHECK=0
case "${1:-start}" in check) CHECK=1 ;; start) ;; *) exit 64 ;; esac

if [ "$CHECK" = 0 ] && [ -r "$TMP/zapret2-nfqws.pid" ]; then
    oldpid=`cat "$TMP/zapret2-nfqws.pid" 2>/dev/null`
    pid_matches "$oldpid" "$BASE/nfqws2" && exit 0
fi

if [ "$CHECK" = 0 ]; then "$BASE/add-rules.sh" || exit 1; fi

set --
if [ "$CHECK" = 1 ]; then
    # nfqws2 writes its PID even with interception disabled. A preflight must
    # leave the running handler's PID and debug log untouched, including on error.
    set -- --intercept=0
else
    set -- "--pidfile=$TMP/zapret2-nfqws.pid"
fi
if [ "$CHECK" = 0 ] && [ "${DEBUG_LOG:-0}" = 1 ]; then
    set -- "$@" "--debug=@$TMP/zapret2-debug.log"
fi

exec "$BASE/nfqws2" \
    "$@" \
    --qnum="$QNUM" \
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
