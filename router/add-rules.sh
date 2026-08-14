#!/bin/sh

. /var/SaaS/zapret2/lib.sh
acquire_rules_lock || exit 0

add4() {
    iptables -t mangle -C "$@" 2>/dev/null || iptables -t mangle -A "$@"
}

iptables -t mangle -N Z2OUT 2>/dev/null || true
iptables -t mangle -N Z2IN 2>/dev/null || true
add4 Z2OUT -p tcp -m multiport --dports 80,443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass
add4 Z2OUT -p udp --dport 443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass
add4 Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags SYN,ACK SYN,ACK -j NFQUEUE --queue-num "$QNUM" --queue-bypass
add4 Z2IN -p udp --sport 443 -j NFQUEUE --queue-num "$QNUM" --queue-bypass
iptables -t mangle -C POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null || iptables -t mangle -I POSTROUTING 1 -o "$WAN" -j Z2OUT
iptables -t mangle -C FORWARD -i "$WAN" -j Z2IN 2>/dev/null || iptables -t mangle -I FORWARD 1 -i "$WAN" -j Z2IN
iptables -t mangle -C INPUT -i "$WAN" -j Z2IN 2>/dev/null || iptables -t mangle -I INPUT 1 -i "$WAN" -j Z2IN

if [ "$ENABLE_IPV6" = 1 ] && command -v ip6tables >/dev/null 2>&1; then
    add6() {
        ip6tables -t mangle -C "$@" 2>/dev/null || ip6tables -t mangle -A "$@"
    }
    ip6tables -t mangle -N Z2OUT 2>/dev/null || true
    ip6tables -t mangle -N Z2IN 2>/dev/null || true
    add6 Z2OUT -p tcp -m multiport --dports 80,443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    add6 Z2OUT -p udp --dport 443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    add6 Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags SYN,ACK SYN,ACK -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    add6 Z2IN -p udp --sport 443 -j NFQUEUE --queue-num "$QNUM" --queue-bypass
    ip6tables -t mangle -C POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null || ip6tables -t mangle -I POSTROUTING 1 -o "$WAN" -j Z2OUT
    ip6tables -t mangle -C FORWARD -i "$WAN" -j Z2IN 2>/dev/null || ip6tables -t mangle -I FORWARD 1 -i "$WAN" -j Z2IN
    ip6tables -t mangle -C INPUT -i "$WAN" -j Z2IN 2>/dev/null || ip6tables -t mangle -I INPUT 1 -i "$WAN" -j Z2IN
fi
