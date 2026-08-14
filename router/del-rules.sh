#!/bin/sh

. /var/SaaS/zapret2/lib.sh
acquire_rules_lock || exit 1

while iptables -t mangle -D POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null; do :; done
while iptables -t mangle -D FORWARD -i "$WAN" -j Z2IN 2>/dev/null; do :; done
while iptables -t mangle -D INPUT -i "$WAN" -j Z2IN 2>/dev/null; do :; done
iptables -t mangle -F Z2OUT 2>/dev/null || true
iptables -t mangle -F Z2IN 2>/dev/null || true
iptables -t mangle -X Z2OUT 2>/dev/null || true
iptables -t mangle -X Z2IN 2>/dev/null || true

if command -v ip6tables >/dev/null 2>&1; then
    while ip6tables -t mangle -D POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null; do :; done
    while ip6tables -t mangle -D FORWARD -i "$WAN" -j Z2IN 2>/dev/null; do :; done
    while ip6tables -t mangle -D INPUT -i "$WAN" -j Z2IN 2>/dev/null; do :; done
    ip6tables -t mangle -F Z2OUT 2>/dev/null || true
    ip6tables -t mangle -F Z2IN 2>/dev/null || true
    ip6tables -t mangle -X Z2OUT 2>/dev/null || true
    ip6tables -t mangle -X Z2IN 2>/dev/null || true
fi
