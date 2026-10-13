#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006
BASE=${Z2_BASE:-/var/SaaS/zapret2}
# shellcheck source=lib.sh
. "$BASE/lib.sh"
lock_rules "${1:-}"
remove_family() {
    TABLE=$1
    for entry in "POSTROUTING -o" "FORWARD -i" "INPUT -i"; do
        # Only these fixed, project-owned arguments are split.
        # Fixed internal pairs intentionally split into positional arguments.
        # shellcheck disable=SC2086
        set -- $entry
        case "$1" in POSTROUTING) chain=Z2OUT ;; *) chain=Z2IN ;; esac
        while "$TABLE" -t mangle -C "$1" "$2" "$WAN" -j "$chain" 2>/dev/null; do
            "$TABLE" -t mangle -D "$1" "$2" "$WAN" -j "$chain" || return 1
        done
    done
    for chain in Z2OUT Z2IN; do
        if "$TABLE" -t mangle -S "$chain" >/dev/null 2>&1; then
            "$TABLE" -t mangle -F "$chain" && "$TABLE" -t mangle -X "$chain" || return 1
        fi
    done
}
remove_family iptables || exit 1
if ip6tables --version >/dev/null 2>&1; then remove_family ip6tables || exit 1; fi
