#!/bin/sh

BASE=/var/SaaS/zapret2
. "$BASE/lib.sh"

echo "version: `cat "$BASE/VERSION" 2>/dev/null`"
echo "wan: $WAN"
echo "storage:"
df -h /var/SaaS 2>/dev/null || true
echo "processes:"
for entry in "/var/tmp/zapret2-nfqws.pid:$BASE/nfqws2" "/var/tmp/zapret2-watch.pid:$BASE/watch-rules.sh"; do
    file=${entry%%:*}
    needle=${entry#*:}
    pid=`cat "$file" 2>/dev/null`
    if pid_matches "$pid" "$needle"; then echo "OK pid=$pid $needle"; else echo "MISSING $needle"; fi
done
echo "appmgr:"
cat "$BASE/appmgr-slots" 2>/dev/null || echo "slots file missing"
echo "ipv4 counters:"
iptables -t mangle -L Z2OUT -n -v 2>/dev/null || true
iptables -t mangle -L Z2IN -n -v 2>/dev/null || true
echo "ipv6 counters:"
ip6tables -t mangle -L Z2OUT -n -v 2>/dev/null || true
ip6tables -t mangle -L Z2IN -n -v 2>/dev/null || true
