#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006
BASE=${Z2_BASE:-/var/SaaS/zapret2}
# shellcheck source=lib.sh
. "$BASE/lib.sh"
lock_rules "${1:-}"

rule() {
    "$TABLE" -t mangle -C "$@" 2>/dev/null || "$TABLE" -t mangle -A "$@"
}
link() {
    "$TABLE" -t mangle -C "$@" 2>/dev/null || "$TABLE" -t mangle -I "$@"
}
apply_family() {
    TABLE=$1
    for chain in Z2OUT Z2IN; do
        "$TABLE" -t mangle -S "$chain" >/dev/null 2>&1 || "$TABLE" -t mangle -N "$chain" || return 1
    done
    project_rules
}
apply_family iptables || exit 1
if [ "$ENABLE_IPV6" = 1 ]; then
    ip6tables --version >/dev/null 2>&1 || exit 1
    apply_family ip6tables || exit 1
fi
