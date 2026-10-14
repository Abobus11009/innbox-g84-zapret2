#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_VERSION=0.4.1
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ROUTER_HOST="${G84_HOST:-192.168.1.1}"
ROUTER_USER="${G84_USER:-superadmin}"
WAN_OVERRIDE="${G84_WAN:-}"
TARGET="$ROUTER_USER@$ROUTER_HOST"
PAYLOAD="$ROOT/g84-zapret2-payload.tar.gz"
MANIFEST="$ROOT/manifest.env"
BACKUP_DIR="$ROOT/backups"
LOG_DIR="$ROOT/logs"
NO_REBOOT=0
DRY_RUN=0
IPV6_ENABLED=1
SSH_BASE=(-o "KexAlgorithms=+diffie-hellman-group1-sha1" -o "HostKeyAlgorithms=+ssh-rsa" -o "ConnectTimeout=8")

usage() {
  cat <<'EOF'
Usage:
  ./g84-zapret2.sh diagnose [--host IP] [--wan IFACE]
  ./g84-zapret2.sh install [--host IP] [--wan IFACE] [--no-reboot] [--dry-run]
  ./g84-zapret2.sh status [--host IP]
  ./g84-zapret2.sh verify [--host IP]
  ./g84-zapret2.sh uninstall [--host IP] [--no-reboot] [--dry-run]
  ./g84-zapret2.sh recover [--host IP]

OpenSSH asks for the router password interactively. The password is not stored.
EOF
}

die() { local code="$1"; shift; printf 'ERROR: %s\n' "$*" >&2; exit "$code"; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}

load_manifest() {
  [[ -r "$MANIFEST" ]] || die 20 "missing $MANIFEST"
  local installer_version="$PROJECT_VERSION"
  # shellcheck disable=SC1090
  source "$MANIFEST"
  [[ "$installer_version" == "$PROJECT_VERSION" ]] || die 22 'installer/payload version mismatch'
  [[ "${PAYLOAD_FILE:-}" == "$(basename "$PAYLOAD")" ]] || die 20 'payload filename does not match manifest'
  local actual
  actual="$(sha256_file "$PAYLOAD")"
  [[ "$actual" == "${PAYLOAD_SHA256:-}" ]] || die 21 'payload checksum mismatch'
}

remote() {
  # The firmware's default /bin/sh lacks functions; force the bundled ash.
  # Use POSIX single quoting, not Bash %q ($'...' is not supported by msh).
  local remote_script="$*"
  remote_script=${remote_script//\'/\'\\\'\'}
  # shellcheck disable=SC2029
  ssh "${SSH_BASE[@]}" "$TARGET" "/bin/ash -c '$remote_script'"
}

upload_payload() {
  remote 'test ! -e /var/tmp/zapret2-install && mkdir /var/tmp/zapret2-install && tar -xzf - -C /var/tmp/zapret2-install' <"$PAYLOAD"
}

port_open() {
  if nc -h 2>&1 | grep -q -- '-G'; then nc -G 1 -z "$ROUTER_HOST" 22 >/dev/null 2>&1
  else nc -w 1 -z "$ROUTER_HOST" 22 >/dev/null 2>&1; fi
}

start_log() {
  mkdir -p "$LOG_DIR"
  local logfile
  logfile="$LOG_DIR/${ACTION}-$(date +%Y%m%d-%H%M%S).log"
  exec > >(tee -a "$logfile") 2>&1
  printf 'g84-zapret2 %s action=%s target=%s\n' "$PROJECT_VERSION" "$ACTION" "$TARGET"
}

detect_wan() {
  local detected
  if [[ -n "$WAN_OVERRIDE" ]]; then printf '%s\n' "$WAN_OVERRIDE"; return; fi
  detected="$(remote "route -n 2>/dev/null | awk '\$1==\"0.0.0.0\" {print \$8; exit}'")"
  [[ -n "$detected" ]] || detected=nas1
  printf '%s\n' "$detected"
}

diagnose() {
  echo '=== Platform ==='
  remote 'uname -a; sed -n "1,30p" /proc/cpuinfo; awk "/^Uid:/{print}" /proc/self/status'
  echo '=== Network and selected WAN ==='
  remote 'route -n 2>/dev/null || true; ifconfig 2>/dev/null || true'
  printf 'selected WAN: %s\n' "$(detect_wan)"
  echo '=== Storage ==='
  remote 'df -h; mount'
  echo '=== Netfilter ==='
  remote 'iptables --version; ip6tables --version 2>/dev/null || true; cat /proc/net/ip_tables_targets 2>/dev/null; grep -Ei "queue|nfnetlink|netfilter" /proc/modules 2>/dev/null || true'
  echo '=== Hardware offload ==='
  remote 'grep -Ei "hnat|ppe|flow|ecnt" /proc/modules 2>/dev/null || true'
  echo '=== Required commands and services ==='
  remote 'busybox 2>/dev/null | sed -n "1,5p"; iptables --version; csmconf -H; csmctl 2>&1 | sed -n "1,2p"; appmgrcmd 2>&1 | sed -n "1,2p"; tar --help 2>&1 | sed -n "1,2p"; ps | grep appmgrd | grep -v grep || true'
}

nfqueue_preflight() {
  local result
  # A cleanup failure is different from unsupported NFQUEUE. Never downgrade
  # IPv6 after leaving a probe rule behind and then report successful preflight.
  # shellcheck disable=SC2016
  if remote 'probe() {
    table=$1; address=$2
    "$table" -t mangle -I OUTPUT 1 -d "$address" -p tcp -j NFQUEUE --queue-num 299 --queue-bypass || return 1
    n=0
    while ! "$table" -t mangle -D OUTPUT -d "$address" -p tcp -j NFQUEUE --queue-num 299 --queue-bypass; do
      n=`expr "$n" + 1`
      [ "$n" -lt 3 ] || return 5
      sleep 1
    done
  }; probe iptables 192.0.2.1'; then :
  else die 31 'IPv4 NFQUEUE probe/cleanup failed; inspect OUTPUT test rule'; fi
  # shellcheck disable=SC2016
  if remote 'probe() {
    table=$1; address=$2
    "$table" -t mangle -I OUTPUT 1 -d "$address" -p tcp -j NFQUEUE --queue-num 299 --queue-bypass || return 1
    n=0
    while ! "$table" -t mangle -D OUTPUT -d "$address" -p tcp -j NFQUEUE --queue-num 299 --queue-bypass; do
      n=`expr "$n" + 1`
      [ "$n" -lt 3 ] || return 5
      sleep 1
    done
  }; probe ip6tables 2001:db8::1'; then :
  else
    result=$?
    [[ "$result" = 1 ]] || die 31 'IPv6 NFQUEUE probe cleanup/SSH failed; inspect OUTPUT test rule'
    IPV6_ENABLED=0
    echo 'WARNING: IPv6 NFQUEUE unavailable; installing IPv4-only mode.'
  fi
}

preflight_install() {
  load_manifest
  remote 'grep -q EN7528 /proc/cpuinfo && grep -q en751221 /proc/cpuinfo' || die 30 'unsupported platform (expected Innbox G84 / EN7528)'
  # Dollar expressions below belong to the remote awk, not local Bash.
  # shellcheck disable=SC2016
  remote 'awk "/^Uid:/{if (\$2==0) exit 0; exit 1}" /proc/self/status' || die 32 'SSH session is not UID 0'
  remote 'test -d /var/SaaS && test -w /var/SaaS' || die 33 '/var/SaaS is not writable'
  remote 'test -x /bin/ash && iptables --version >/dev/null 2>&1 && csmconf -H >/dev/null 2>&1 && { csmctl 2>&1 | grep -q csmctl; } && { appmgrcmd 2>&1 | grep -q appmgrcmd; } && { tar --help 2>&1 | grep -q Usage; } && { ps | grep appmgrd | grep -v grep >/dev/null; }' || die 34 'required firmware commands or appmgrd are missing'
  local free_kib
  free_kib="$(remote 'df -k /var/SaaS' | tr -d '\r' | awk 'NF>=4 && $4 ~ /^[0-9]+$/ {v=$4} END {print v}')"
  [[ "$free_kib" =~ ^[0-9]+$ && "$free_kib" -ge 650 ]] || die 35 'less than 650 KiB free on /var/SaaS'
}

prune_backups() {
  local file name stamp mtime rows=() expired
  # A config XML anchors a backup set; never sort unrelated filename prefixes.
  # Orphan archives and unrelated files are left alone, not counted as XML sets.
  for file in "$BACKUP_DIR"/g84-config-*.xml; do
    [[ -f "$file" && ! -L "$file" ]] || continue
    name=${file##*/}; stamp=${name#g84-config-}; stamp=${stamp%.xml}
    [[ "$stamp" =~ ^[0-9]{8}-[0-9]{6}(-[0-9]+)?$ ]] || continue
    if mtime="$(stat -c %Y "$file" 2>/dev/null)"; then :
    else mtime="$(stat -f %m "$file")" || return 1; fi
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    [[ ! -d "$BACKUP_DIR/.reserve-$stamp" ]] || continue
    rows+=("$mtime $stamp")
  done
  ((${#rows[@]} > 10)) || return 0
  expired="$(printf '%s\n' "${rows[@]}" | sort -nr | tail -n +11)" || return 1
  while read -r mtime stamp; do
    rm -f "$BACKUP_DIR/g84-config-$stamp.xml" "$BACKUP_DIR/g84-zapret2-$stamp.tar.gz" || return 1
  done <<<"$expired"

}

backup_router() {
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || die 38 'cannot create private backup directory'
  local stamp config_backup install_backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  local base_stamp="$stamp" suffix=0
  while ! mkdir "$BACKUP_DIR/.reserve-$stamp" 2>/dev/null; do
    [[ -d "$BACKUP_DIR/.reserve-$stamp" ]] || die 38 'cannot reserve backup name'
    suffix=$((suffix + 1)); stamp="$base_stamp-$suffix"
  done
  while [[ -e "$BACKUP_DIR/g84-config-$stamp.xml" || -e "$BACKUP_DIR/g84-zapret2-$stamp.tar.gz" ]]; do
    rmdir "$BACKUP_DIR/.reserve-$stamp" || die 38 'cannot release backup reservation'
    suffix=$((suffix + 1)); stamp="$base_stamp-$suffix"
    mkdir "$BACKUP_DIR/.reserve-$stamp" || die 38 'cannot reserve backup name'
  done
  config_backup="$BACKUP_DIR/g84-config-$stamp.xml"
  install_backup="$BACKUP_DIR/g84-zapret2-$stamp.tar.gz"
  remote "csmconf -D /var/tmp/g84-config-$stamp.xml" || die 38 'configuration export failed'
  remote "test -s /var/tmp/g84-config-$stamp.xml && cat /var/tmp/g84-config-$stamp.xml" >"$config_backup" || die 38 'configuration download failed'
  [[ -s "$config_backup" ]] || die 38 "empty configuration backup"
  remote "rm -f /var/tmp/g84-config-$stamp.xml" || true
  chmod 600 "$config_backup" || die 38 'cannot protect configuration backup'
  if remote 'test -d /var/SaaS/zapret2'; then
    remote 'tar -czf - -C /var/SaaS zapret2' >"$install_backup" || die 38 'installation backup failed'
    [[ -s "$install_backup" ]] || die 38 'empty installation backup'
    chmod 600 "$install_backup" || die 38 'cannot protect installation backup'
  else
    local backup_status=$?
    [[ "$backup_status" = 1 ]] || die 38 'cannot determine installation backup state'
  fi
  rmdir "$BACKUP_DIR/.reserve-$stamp" || die 38 'cannot release backup reservation'
  prune_backups || die 38 'backup pruning failed'
  echo "Backup saved under $BACKUP_DIR (private, gitignored)."
}

find_appmgr_slots() {
  local listing nfq='' watcher='' free=()
  # Variables and substitutions in this string belong to the router shell.
  # shellcheck disable=SC2016
  listing="$(remote 'i=1; while [ $i -le 16 ]; do n=`csmconf -g /appmgr:$i/name 2>/dev/null` || exit 1; echo "$i:$n"; i=`expr $i + 1`; done' | tr -d '\r')" || return 1
  [[ "$(printf '%s\n' "$listing" | wc -l | tr -d ' ' )" = 16 ]] || return 1
  while IFS=: read -r slot name; do
    [[ "$name" == zapret2 ]] && nfq="$slot"
    [[ "$name" == zapret2-rules ]] && watcher="$slot"
    [[ -z "$name" ]] && free+=("$slot")
  done <<<"$listing"
  [[ -n "$nfq" ]] || { ((${#free[@]} >= 1)) || return 1; nfq="${free[0]}"; free=("${free[@]:1}"); }
  [[ -n "$watcher" ]] || { ((${#free[@]} >= 1)) || return 1; watcher="${free[0]}"; }
  printf '%s %s\n' "$nfq" "$watcher"
}

verify() {
  remote 'test -x /var/SaaS/zapret2/verify.sh && /var/SaaS/zapret2/verify.sh' \
    || { echo 'service verification failed' >&2; return 40; }
  remote '/var/SaaS/zapret2/status.sh' || { echo 'status read failed' >&2; return 40; }
}

recover() {
  remote 'test -r /var/SaaS/zapret2.transaction/recover.sh && /bin/ash /var/SaaS/zapret2.transaction/recover.sh recover' \
    || die 52 'recovery failed; preserve journal and backups for diagnosis'
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR" || die 38 'cannot create private backup directory'
  local journal_backup
  journal_backup="$BACKUP_DIR/g84-recovery-$(date +%Y%m%d-%H%M%S).tar.gz"
  remote 'tar -czf - -C /var/SaaS zapret2.transaction' >"$journal_backup" || die 52 'cannot save recovery journal locally'
  chmod 600 "$journal_backup" || die 38 'cannot protect recovery journal'
  remote 'rm -rf /var/SaaS/zapret2.transaction /var/SaaS/zapret2.new /var/SaaS/zapret2.failed /var/tmp/zapret2-install' || die 52 'recovery verified but cleanup failed'
}

wait_after_reboot() {
  echo 'Waiting for SSH to disappear...'
  local i current_boot
  [[ -n "${1:-}" ]] || { echo 'missing previous boot ID' >&2; return 1; }
  i=30
  while (( i-- > 0 )); do port_open || break; sleep 2; done
  echo 'Waiting for SSH to return...'
  i=90
  while (( i-- > 0 )); do
    if port_open; then
      sleep 5
      current_boot="$(remote 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r')" || return 1
      [[ "$current_boot" != "$1" && -n "$current_boot" ]] || { echo 'reboot has not been confirmed' >&2; return 1; }
      verify
      return $?
    fi
    sleep 2
  done
  echo 'router did not return to SSH after reboot' >&2; return 1
}

install_zapret2() {
  preflight_install
  local wan slots nfq_slot watch_slot replace_wan=0
  [[ -z "$WAN_OVERRIDE" ]] || replace_wan=1
  wan="$(detect_wan)"
  [[ "$wan" =~ ^[a-zA-Z0-9_.:-]+$ ]] || die 2 'invalid WAN interface'
  slots="$(find_appmgr_slots)" || die 36 'two free/owned appmgr slots are required'
  read -r nfq_slot watch_slot <<<"$slots"
  echo "Plan: WAN=$wan appmgr=($nfq_slot,$watch_slot) version=$PROJECT_VERSION IPv6=$IPV6_ENABLED"
  (( DRY_RUN )) && { echo 'Dry run: no router changes made; live NFQUEUE probe skipped.'; return; }
  nfqueue_preflight
  backup_router || die 38 'backup failed'
  upload_payload || die 23 'payload upload failed; staging retained'
  remote "/bin/ash /var/tmp/zapret2-install/zapret2/install-transaction.sh install '$wan' '$IPV6_ENABLED' '$nfq_slot' '$watch_slot' '$PROJECT_VERSION' '$replace_wan'" \
    || die 51 'installation failed; inspect rollback result and recovery journal'
  if (( NO_REBOOT )); then
    verify || { recover; die 40 'post-install verification failed; rollback requested'; }
    echo 'Current service verified; reboot persistence has not been tested.'
  else
    local previous_boot
    previous_boot="$(remote 'cat /proc/sys/kernel/random/boot_id' | tr -d '\r')" || { recover; die 41 'cannot record boot ID; previous state restored'; }
    remote 'reboot' >/dev/null 2>&1 || true
    if ! wait_after_reboot "$previous_boot"; then
      echo 'Post-reboot verification failed. Attempting recovery; retain backups if SSH is unavailable.' >&2
      recover
      die 41 'post-reboot verification failed; previous state restored'
    fi
  fi
  # Cleanup is separate from committing: failure must not hide a working installation.
  remote 'rm -rf /var/SaaS/zapret2.old /var/SaaS/zapret2.transaction /var/tmp/zapret2-install' \
    || echo 'WARNING: verified installation has retained cleanup/recovery files.' >&2
}

status() { remote '/var/SaaS/zapret2/status.sh 2>/dev/null || { echo "zapret2 is not installed"; exit 1; }'; }

# BEGIN EMBEDDED UNINSTALL
upload_uninstall_tools() {
  remote 'test ! -e /var/tmp/zapret2-uninstall && mkdir /var/tmp/zapret2-uninstall && chmod 700 /var/tmp/zapret2-uninstall && /bin/ash -s' <<'G84_EMBEDDED_TOOLS'
cat > /var/tmp/zapret2-uninstall/lib.sh <<'G84_SOURCE_LIB_SH' || exit 1
#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006

BASE=${Z2_BASE:-/var/SaaS/zapret2}
TMP=${Z2_TMP:-/var/tmp}
PROC=${Z2_PROC:-/proc}
# shellcheck source=config
if [ -r "$BASE/config" ]; then . "$BASE/config" || exit 1; fi
WAN=${WAN:-nas1}
QNUM=${QNUM:-200}
MARK=${MARK:-0x40000000}
ENABLE_IPV6=${ENABLE_IPV6:-1}
LOCK=$TMP/zapret2-rules.flock

pid_matches() (
    [ -n "$1" ] && [ -r "$PROC/$1/cmdline" ] || exit 1
    first=`tr '\000' '\n' < "$PROC/$1/cmdline" | sed -n '1p'`
    second=`tr '\000' '\n' < "$PROC/$1/cmdline" | sed -n '2p'`
    [ "$first" = "$2" ] && exit 0
    case "$first" in
        */ash|*/sh) [ "$second" = "$2" ] ;;
        *) exit 1 ;;
    esac
)

owned_pids() (
    # Prefilter in one grep process; exact argv checks still decide ownership.
    # Scanning every kernel thread with separate tr/sed processes is slow on G84.
    candidates=`grep -l -F "$1" "$PROC"/[0-9]*/cmdline 2>/dev/null` || :
    for f in $candidates; do
        [ -r "$f" ] || continue
        p=${f%/cmdline}; p=${p##*/}
        if pid_matches "$p" "$1"; then echo "$p"; fi
    done
)

stop_pidfile() (
    [ -r "$1" ] || exit 0
    p=`cat "$1"` || exit 1
    if pid_matches "$p" "$2"; then
        kill "$p" || exit 1
        n=0
        while pid_matches "$p" "$2"; do
            n=`expr "$n" + 1`
            if [ "$n" = 10 ]; then
                # Legacy watcher traps TERM without exiting; kill only this exact owner.
                pid_matches "$p" "$2" && kill -9 "$p" || exit 1
            fi
            [ "$n" -lt 13 ] || { echo "process did not stop: $p" >&2; exit 1; }
            sleep 1
        done
    elif [ -r "$PROC/$p/cmdline" ]; then
        echo "PID file belongs to another process: $1" >&2
        exit 1
    fi
    rm -f "$1"
)

# Used only by add-rules.sh/del-rules.sh, not by the packet handler.
# The kernel lock file is permanent until reboot and must never be removed.
lock_rules() {
    if [ "${1:-}" != --locked ]; then
        exec "$BASE/g84-lock" "$LOCK" 10 "${Z2_SHELL:-/bin/ash}" "$0" --locked
    fi
}

# One definition of every project rule: both application and verification use it.
project_rules() {
    rule Z2OUT -p tcp -m multiport --dports 80,443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2OUT -p udp --dport 443 -m mark ! --mark "$MARK/$MARK" -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags SYN,ACK SYN,ACK -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags RST RST -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p tcp -m multiport --sports 80,443 --tcp-flags FIN FIN -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    rule Z2IN -p udp --sport 443 -j NFQUEUE --queue-num "$QNUM" --queue-bypass || return 1
    link POSTROUTING -o "$WAN" -j Z2OUT || return 1
    link FORWARD -i "$WAN" -j Z2IN || return 1
    link INPUT -i "$WAN" -j Z2IN || return 1
}

G84_SOURCE_LIB_SH
cat > /var/tmp/zapret2-uninstall/install-transaction.sh <<'G84_SOURCE_INSTALL_TRANSACTION_SH' || exit 1
#!/bin/ash
# shellcheck shell=dash
# BusyBox 1.00 compatibility: retain expr and legacy command substitution.
# shellcheck disable=SC2003,SC2006
# Run the staged copy: all errors are explicit, including inside conditionals.
BASE=${Z2_BASE:-/var/SaaS/zapret2}
TMP=${Z2_TMP:-/var/tmp}
PROC=${Z2_PROC:-/proc}
STAGE=${Z2_STAGE:-$TMP/zapret2-install/zapret2}
JOURNAL=$BASE.transaction
NEXT=$BASE.new
OLD=$BASE.old
FAILED=$BASE.failed
umask 077
FIELDS='name path argument auto_start crash_start'
SELF_DIR=${0%/*}
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh" || exit 1

write_state() { printf '%s\n' "$2" > "$JOURNAL/$1"; }
read_state() { cat "$JOURNAL/$1"; }

save_slot() {
    slot=$1; expected=$2
    mkdir "$JOURNAL/slot-$slot" || return 1
    # A vacant slot has no name; do not infer that other read failures are vacancy.
    name=`csmconf -g "/appmgr:$slot/name" 2>/dev/null` || return 1
    if [ -z "$name" ]; then
        : > "$JOURNAL/slot-$slot/vacant" || return 1
        return 0
    fi
    [ "$name" = "$expected" ] || { echo "slot $slot is not owned by $expected" >&2; return 1; }
    for field in $FIELDS; do
        if value=`csmconf -g "/appmgr:$slot/$field" 2>/dev/null`; then
            printf '%s' "$value" > "$JOURNAL/slot-$slot/$field" || return 1
        else
            # Refuse ambiguous reads of a populated slot. Never guess an old value.
            echo "cannot snapshot /appmgr:$slot/$field" >&2
            return 1
        fi
    done
    case "$expected" in zapret2) expected_path=$BASE/run.sh ;; *) expected_path=$BASE/watch-rules.sh ;; esac
    [ "`cat "$JOURNAL/slot-$slot/path"`" = "$expected_path" ] || return 1
}

restore_slot() {
    slot=$1
    if [ -f "$JOURNAL/slot-$slot/vacant" ]; then
        name=`csmconf -g "/appmgr:$slot/name" 2>/dev/null` || return 1
        if [ -n "$name" ]; then
            case "$name" in zapret2|zapret2-rules) ;; *) echo 'rollback refuses foreign appmgr slot' >&2; return 1 ;; esac
            csmconf -d "/appmgr:$slot" || return 1
            name=`csmconf -g "/appmgr:$slot/name"` || return 1
            [ -z "$name" ] || return 1
        fi
    else
        for field in $FIELDS; do
            value=`cat "$JOURNAL/slot-$slot/$field"` || return 1
            csmconf -s "/appmgr:$slot/$field" "$value" || return 1
            actual=`csmconf -g "/appmgr:$slot/$field"` || return 1
            [ "$actual" = "$value" ] || return 1
        done
    fi
}

set_key() {
    csmconf -s "$1" "$2" || return 1
    actual=`csmconf -g "$1"` || return 1
    [ "$actual" = "$2" ] || { echo "appmgr read-back mismatch: $1" >&2; return 1; }
}

register_slot() {
    slot=$1; name=$2; path=$3
    set_key "/appmgr:$slot/name" "$name" &&
    set_key "/appmgr:$slot/path" "$path" &&
    set_key "/appmgr:$slot/argument" start &&
    set_key "/appmgr:$slot/auto_start" 1 &&
    set_key "/appmgr:$slot/crash_start" 1
}

stop_services() {
    # appmgrcmd may return nonzero after a successful IPC request on this firmware.
    # Verify actual process termination instead of trusting that return code.
    appmgrcmd stop zapret2-rules 2>/dev/null || true
    appmgrcmd stop zapret2 2>/dev/null || true
    for file in "$TMP/zapret2-watch.pid:$BASE/watch-rules.sh" "$TMP/zapret2-nfqws.pid:$BASE/nfqws2"; do
        stop_pidfile "${file%%:*}" "${file#*:}" || return 1
    done
    # Legacy installations may have no watcher PID file.
    for path in "$BASE/nfqws2" "$BASE/watch-rules.sh" "$BASE/add-rules.sh" "$BASE/del-rules.sh" "$BASE/g84-lock"; do
        pids=`owned_pids "$path"` || return 1
        for p in $pids; do kill "$p" 2>/dev/null || return 1; done
        n=0
        while [ -n "`owned_pids "$path"`" ]; do
            n=`expr "$n" + 1`
            if [ "$n" = 10 ]; then
                for p in `owned_pids "$path"`; do pid_matches "$p" "$path" && kill -9 "$p" || return 1; done
            fi
            [ "$n" -lt 13 ] || return 1
            sleep 1
        done
    done
}

start_one() {
    name=$1; path=$2; argument=${3:-start}; restart=${4:-1}
    case "$name" in zapret2) process=$BASE/nfqws2 ;; *) process=$path ;; esac
    appmgrcmd add "$name" "$path" "$argument" "$restart" 2>/dev/null || true
    n=0
    while [ -z "`owned_pids "$process"`" ]; do
        n=`expr "$n" + 1`
        if [ "$n" = 3 ]; then
            # Firmware IPC can be unavailable until reboot. Registration is saved;
            # directly launch this owned script and still require a matching process.
            echo "appmgr live start unavailable; launching $name directly" >&2
            case "$name" in zapret2) log=$TMP/zapret2.log ;; *) log=$TMP/zapret2-rules.log ;; esac
            "${Z2_SHELL:-/bin/ash}" "$path" "$argument" </dev/null >"$log" 2>&1 &
        fi
        [ "$n" -lt 10 ] || { echo "service failed to start: $name" >&2; return 1; }
        sleep 1
    done
}

rollback() {
    if [ -r "$JOURNAL/result" ] && [ "`read_state result`" = rolled-back ]; then return 0; fi
    echo 'Restoring previous installation and owned appmgr settings...' >&2
    nfq_slot=`read_state nfq-slot` || return 1
    watch_slot=`read_state watch-slot` || return 1
    if [ -f "$JOURNAL/stop-started" ]; then
        stop_services || return 1
        if [ -f "$JOURNAL/switch-started" ] && { [ -d "$OLD" ] || [ ! -f "$JOURNAL/had-installation" ]; }; then
            # If the first rename succeeded and the second failed, BASE is absent.
            if [ -d "$BASE" ]; then
                "$BASE/del-rules.sh" || return 1
                [ ! -e "$FAILED" ] || return 1
                mv "$BASE" "$FAILED" || return 1
            fi
            if [ -d "$OLD" ]; then mv "$OLD" "$BASE" || return 1; fi
        fi
    fi
    if [ -f "$JOURNAL/register-started" ]; then
        restore_slot "$nfq_slot" && restore_slot "$watch_slot" && csmctl savecfg || return 1
    fi
    if [ -f "$JOURNAL/stop-started" ] && [ -f "$JOURNAL/had-installation" ]; then
        if [ -f "$JOURNAL/nfq-running" ]; then
            argument=`cat "$JOURNAL/slot-$nfq_slot/argument" 2>/dev/null` || argument=start
            restart=`cat "$JOURNAL/slot-$nfq_slot/crash_start" 2>/dev/null` || restart=1
            start_one zapret2 "$BASE/run.sh" "$argument" "$restart" || return 1
            [ -n "`owned_pids "$BASE/nfqws2"`" ] || return 1
        fi
        if [ -f "$JOURNAL/watch-running" ]; then
            argument=`cat "$JOURNAL/slot-$watch_slot/argument" 2>/dev/null` || argument=start
            restart=`cat "$JOURNAL/slot-$watch_slot/crash_start" 2>/dev/null` || restart=1
            start_one zapret2-rules "$BASE/watch-rules.sh" "$argument" "$restart" || return 1
        fi
    fi
    if [ -f "$JOURNAL/stop-started" ] && [ -f "$JOURNAL/had-installation" ] && [ -f "$JOURNAL/rules-present" ]; then
        "$BASE/add-rules.sh" || return 1
    fi
    write_state result rolled-back || return 1
    echo 'Rollback completed. Recovery journal and failed files are retained.' >&2
}

abort_transaction() {
    trap - 0 1 2 15
    if [ -f "$JOURNAL/snapshot-complete" ]; then
        if ! rollback; then
            echo "ROLLBACK FAILED: preserve $JOURNAL, $OLD and $FAILED; run recover after diagnosis" >&2
            exit 52
        fi
    else
        echo "Preparation failed before service changes; preserve $JOURNAL and $NEXT" >&2
    fi
    exit 51
}

recover() {
    [ -r "$JOURNAL/snapshot-complete" ] || { echo 'no complete recovery journal' >&2; return 1; }
    rollback
}

install() {
    wan=$1; ipv6=$2; nfq_slot=$3; watch_slot=$4; version=$5; replace_wan=${6:-0}
    case "$wan" in ''|*[!a-zA-Z0-9_.:-]*) echo 'invalid WAN' >&2; return 1 ;; esac
    case "$ipv6" in 0|1) ;; *) return 1 ;; esac
    case "$replace_wan" in 0|1) ;; *) return 1 ;; esac
    case "$nfq_slot:$watch_slot" in *[!0-9:]*|:*) return 1 ;; esac
    [ "$nfq_slot" -ge 1 ] && [ "$nfq_slot" -le 16 ] && [ "$watch_slot" -ge 1 ] && [ "$watch_slot" -le 16 ] && [ "$nfq_slot" != "$watch_slot" ] || return 1
    for occupied in "$JOURNAL" "$NEXT" "$OLD" "$FAILED"; do
        [ ! -e "$occupied" ] || { echo "recovery data already exists: $occupied" >&2; return 1; }
    done
    mkdir "$JOURNAL" || return 1
    chmod 700 "$JOURNAL" || return 1
    trap abort_transaction 0 1 2 15
    cp "$STAGE/install-transaction.sh" "$JOURNAL/recover.sh" && cp "$STAGE/lib.sh" "$JOURNAL/lib.sh" || return 1
    write_state nfq-slot "$nfq_slot" && write_state watch-slot "$watch_slot" || return 1
    save_slot "$nfq_slot" zapret2 && save_slot "$watch_slot" zapret2-rules || return 1
    if [ -d "$BASE" ]; then : > "$JOURNAL/had-installation" || return 1; fi
    if [ -n "`owned_pids "$BASE/nfqws2"`" ]; then : > "$JOURNAL/nfq-running" || return 1; fi
    if [ -n "`owned_pids "$BASE/watch-rules.sh"`" ]; then : > "$JOURNAL/watch-running" || return 1; fi
    if iptables -t mangle -C POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null; then
        : > "$JOURNAL/rules-present" || return 1
    fi
    : > "$JOURNAL/snapshot-complete" || return 1
    mkdir "$NEXT" && cp -f "$STAGE"/* "$NEXT/" || return 1
    # nfqws2 drops privileges before reopening hostlists: directory must be traversable.
    chmod 755 "$NEXT" || return 1
    chmod 755 "$NEXT"/*.sh "$NEXT/nfqws2" "$NEXT/g84-lock" || return 1
    chmod 644 "$NEXT"/*.lua "$NEXT"/*.txt "$NEXT/config" "$NEXT/VERSION" || return 1
    if [ -d "$BASE" ]; then
        # These files belong to the user; never replace them with payload defaults.
        for file in config hosts.txt hosts-exclude.txt; do
            [ -r "$BASE/$file" ] || return 1
            cp -pf "$BASE/$file" "$NEXT/$file" || return 1
        done
        if [ "$replace_wan" = 1 ]; then printf '\nWAN=%s\n' "$wan" >> "$NEXT/config" || return 1; fi
        # An unavailable kernel facility cannot be kept enabled. Never enable it
        # over a user's explicit IPv4-only choice merely because it is available.
        if [ "$ipv6" = 0 ] && [ "$ENABLE_IPV6" != 0 ]; then printf '\nENABLE_IPV6=0\n' >> "$NEXT/config" || return 1; fi
    else
        printf 'WAN=%s\nQNUM=200\nMARK=0x40000000\nENABLE_IPV6=%s\nDEBUG_LOG=0\n' "$wan" "$ipv6" > "$NEXT/config" || return 1
    fi
    printf 'NFQWS_SLOT=%s\nWATCH_SLOT=%s\n' "$nfq_slot" "$watch_slot" > "$NEXT/appmgr-slots" || return 1
    [ "`cat "$NEXT/VERSION"`" = "$version" ] || return 1
    Z2_BASE="$NEXT" "$NEXT/run.sh" check || return 1
    # Verify kernel locking before touching services; an unsupported helper fails closed.
    "$NEXT/g84-lock" "$TMP/zapret2-install-probe.flock" 0 "${Z2_SHELL:-/bin/ash}" -c ':' || return 1
    : > "$JOURNAL/stop-started" || return 1
    stop_services || return 1
    if [ -d "$BASE" ]; then "$BASE/del-rules.sh" || return 1; fi
    : > "$JOURNAL/switch-started" || return 1
    if [ -d "$BASE" ]; then mv "$BASE" "$OLD" || return 1; fi
    mv "$NEXT" "$BASE" || return 1
    : > "$JOURNAL/register-started" || return 1
    register_slot "$nfq_slot" zapret2 "$BASE/run.sh" && register_slot "$watch_slot" zapret2-rules "$BASE/watch-rules.sh" && csmctl savecfg || return 1
    start_one zapret2 "$BASE/run.sh" && start_one zapret2-rules "$BASE/watch-rules.sh" || return 1
    "$BASE/verify.sh" || return 1
    write_state result committed || return 1
    trap - 0 1 2 15
    # Keep OLD/journal through the host's optional reboot verification.
    echo 'Installation committed; previous files retained until final verification.'
}

remove_owned_slot() {
    slot=$1; expected=$2
    name=`csmconf -g "/appmgr:$slot/name"` || return 1
    [ -n "$name" ] || return 0
    [ "$name" = "$expected" ] || return 1
    # Clear only fields we snapshot. Deleting the entire node would destroy
    # firmware/user extension fields that cannot be restored by this journal.
    set_key "/appmgr:$slot/auto_start" 0 &&
    set_key "/appmgr:$slot/crash_start" 0 &&
    set_key "/appmgr:$slot/path" '' &&
    set_key "/appmgr:$slot/argument" '' &&
    set_key "/appmgr:$slot/name" ''
}

verify_removed() {
    [ -z "`owned_pids "$BASE/nfqws2"`" ] && [ -z "`owned_pids "$BASE/watch-rules.sh"`" ] || return 1
    for table in iptables ip6tables; do
        if [ "$table" = ip6tables ] && ! ip6tables --version >/dev/null 2>&1; then
            [ "$ENABLE_IPV6" = 0 ] || return 1
            continue
        fi
        rules=`"$table" -t mangle -S` || return 1
        if printf '%s\n' "$rules" | grep -E '(^-[NA] Z2(OUT|IN)( |$)| -j Z2(OUT|IN)( |$))' >/dev/null; then return 1; fi
    done
}

uninstall() {
    nfq_slot=$1; watch_slot=$2
    case "$nfq_slot:$watch_slot" in *[!0-9:]*|:*) return 1 ;; esac
    [ "$nfq_slot" -ge 1 ] && [ "$nfq_slot" -le 16 ] && [ "$watch_slot" -ge 1 ] && [ "$watch_slot" -le 16 ] && [ "$nfq_slot" != "$watch_slot" ] || return 1
    [ -d "$BASE" ] || return 1
    for occupied in "$JOURNAL" "$NEXT" "$OLD" "$FAILED"; do
        [ ! -e "$occupied" ] || { echo "recovery data exists: $occupied" >&2; return 1; }
    done
    mkdir "$JOURNAL" && chmod 700 "$JOURNAL" || return 1
    trap abort_transaction 0 1 2 15
    cp "$SELF_DIR/install-transaction.sh" "$JOURNAL/recover.sh" && cp "$SELF_DIR/lib.sh" "$JOURNAL/lib.sh" || return 1
    write_state nfq-slot "$nfq_slot" && write_state watch-slot "$watch_slot" || return 1
    save_slot "$nfq_slot" zapret2 && save_slot "$watch_slot" zapret2-rules || return 1
    : > "$JOURNAL/had-installation" || return 1
    if [ -n "`owned_pids "$BASE/nfqws2"`" ]; then : > "$JOURNAL/nfq-running" || return 1; fi
    if [ -n "`owned_pids "$BASE/watch-rules.sh"`" ]; then : > "$JOURNAL/watch-running" || return 1; fi
    if iptables -t mangle -C POSTROUTING -o "$WAN" -j Z2OUT 2>/dev/null; then : > "$JOURNAL/rules-present" || return 1; fi
    : > "$JOURNAL/snapshot-complete" || return 1
    : > "$JOURNAL/stop-started" || return 1
    stop_services && "$BASE/del-rules.sh" || return 1
    : > "$JOURNAL/register-started" || return 1
    remove_owned_slot "$watch_slot" zapret2-rules && remove_owned_slot "$nfq_slot" zapret2 && csmctl savecfg || return 1
    verify_removed || return 1
    : > "$JOURNAL/switch-started" || return 1
    mv "$BASE" "$OLD" || return 1
    verify_removed || return 1
    write_state result uninstall-committed || return 1
    trap - 0 1 2 15
    echo 'Uninstall committed; old files and journal retained until host cleanup.'
}

case "${1:-}" in
    install) { [ "$#" = 6 ] || [ "$#" = 7 ]; } || exit 64; shift; install "$@" || exit 51 ;;
    uninstall) [ "$#" = 3 ] || exit 64; shift; uninstall "$@" || exit 51 ;;
    recover) recover || exit 52 ;;
    *) echo 'usage: install-transaction.sh install WAN IPV6 NFQ_SLOT WATCH_SLOT VERSION [REPLACE_WAN] | recover' >&2; exit 64 ;;
esac

G84_SOURCE_INSTALL_TRANSACTION_SH
G84_EMBEDDED_TOOLS
}
# END EMBEDDED UNINSTALL

uninstall_zapret2() {
  local present_status
  if remote 'test -d /var/SaaS/zapret2'; then
    :
  else
    present_status=$?
    [[ "$present_status" = 1 ]] || die 53 'cannot determine installation state; SSH/read failure'
    echo 'zapret2 is already absent.'
    return 0
  fi
  echo 'Plan: stop services, remove owned appmgr slots/rules and /var/SaaS/zapret2.'
  (( DRY_RUN )) && { echo 'Dry run: no changes made.'; return; }
  backup_router
  local slots nfq_slot watch_slot
  slots="$(remote 'cat /var/SaaS/zapret2/appmgr-slots')" || die 53 'cannot read appmgr slot mapping; installation retained'
  nfq_slot="$(awk -F= '$1=="NFQWS_SLOT"{print $2}' <<<"$slots")"
  watch_slot="$(awk -F= '$1=="WATCH_SLOT"{print $2}' <<<"$slots")"
  [[ "$nfq_slot" =~ ^([1-9]|1[0-6])$ && "$watch_slot" =~ ^([1-9]|1[0-6])$ && "$nfq_slot" != "$watch_slot" ]] \
    || die 53 'invalid appmgr slot mapping; installation retained'
  upload_uninstall_tools || die 53 'cannot stage uninstall tools; service unchanged'
  remote "/bin/ash /var/tmp/zapret2-uninstall/install-transaction.sh uninstall '$nfq_slot' '$watch_slot'" \
    || die 53 'uninstall failed; inspect automatic rollback and recovery journal'
  # shellcheck disable=SC2016
  remote 'test ! -e /var/SaaS/zapret2 && test "`cat /var/SaaS/zapret2.transaction/result`" = uninstall-committed && rm -rf /var/SaaS/zapret2.old /var/SaaS/zapret2.transaction /var/tmp/zapret2-uninstall' \
    || echo 'WARNING: uninstall committed; cleanup/recovery files retained.' >&2
  (( NO_REBOOT )) || { remote 'reboot' >/dev/null 2>&1 || true; echo 'Router is rebooting.'; }
}

check_dependencies() {
  command -v ssh >/dev/null || die 10 'ssh client not found'
  if [[ "$ACTION" = install ]] && (( !NO_REBOOT && !DRY_RUN )); then
    command -v nc >/dev/null || die 10 'nc is required for reboot monitoring; use --no-reboot or the desktop installer'
  fi
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then return 0; fi

[[ $# -ge 1 ]] || { usage; exit 1; }
ACTION="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || die 2 '--host requires value'; ROUTER_HOST="$2"; TARGET="$ROUTER_USER@$ROUTER_HOST"; shift 2 ;;
    --wan) [[ $# -ge 2 ]] || die 2 '--wan requires value'; WAN_OVERRIDE="$2"; shift 2 ;;
    --no-reboot) NO_REBOOT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die 2 "unknown option: $1" ;;
  esac
done

check_dependencies
start_log
case "$ACTION" in
  diagnose) diagnose ;;
  install) install_zapret2 ;;
  status) status ;;
  verify) verify ;;
  uninstall) uninstall_zapret2 ;;
  recover) recover ;;
  *) usage; die 2 "unknown command: $ACTION" ;;
esac
