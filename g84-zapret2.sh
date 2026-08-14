#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_VERSION=0.2.0
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
  # Arguments after TARGET are intentionally evaluated by the remote shell.
  # shellcheck disable=SC2029
  ssh "${SSH_BASE[@]}" "$TARGET" "$@"
}

upload_payload() {
  remote 'rm -rf /var/tmp/zapret2-install; mkdir -p /var/tmp/zapret2-install; tar -xzf - -C /var/tmp/zapret2-install' <"$PAYLOAD"
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
  remote 'iptables -t mangle -I OUTPUT 1 -d 192.0.2.1 -p tcp -j NFQUEUE --queue-num 299 --queue-bypass && iptables -t mangle -D OUTPUT -d 192.0.2.1 -p tcp -j NFQUEUE --queue-num 299 --queue-bypass' \
    || die 31 'IPv4 NFQUEUE test failed'
  if ! remote 'ip6tables -t mangle -I OUTPUT 1 -d 2001:db8::1 -p tcp -j NFQUEUE --queue-num 299 --queue-bypass && ip6tables -t mangle -D OUTPUT -d 2001:db8::1 -p tcp -j NFQUEUE --queue-num 299 --queue-bypass'; then
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
  remote 'iptables --version >/dev/null 2>&1; csmconf -H >/dev/null 2>&1; csmctl 2>&1 | grep -q csmctl; appmgrcmd 2>&1 | grep -q appmgrcmd; tar --help 2>&1 | grep -q Usage; ps | grep appmgrd | grep -v grep >/dev/null' || die 34 'required firmware commands or appmgrd are missing'
  local free_kib
  free_kib="$(remote 'df -k /var/SaaS' | tr -d '\r' | awk 'NF>=4 && $4 ~ /^[0-9]+$/ {v=$4} END {print v}')"
  [[ "$free_kib" =~ ^[0-9]+$ && "$free_kib" -ge 650 ]] || die 35 'less than 650 KiB free on /var/SaaS'
  nfqueue_preflight
}

prune_backups() {
  local files
  files="$(find "$BACKUP_DIR" -type f -maxdepth 1 2>/dev/null | sort -r | tail -n +11 || true)"
  [[ -z "$files" ]] || while IFS= read -r file; do rm -f "$file"; done <<<"$files"
}

backup_router() {
  mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  local stamp config_backup install_backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  config_backup="$BACKUP_DIR/g84-config-$stamp.xml"
  install_backup="$BACKUP_DIR/g84-zapret2-$stamp.tar.gz"
  remote "csmconf -D /var/tmp/g84-config-$stamp.xml"
  remote "cat /var/tmp/g84-config-$stamp.xml; rm -f /var/tmp/g84-config-$stamp.xml" >"$config_backup"
  chmod 600 "$config_backup"
  if remote 'test -d /var/SaaS/zapret2'; then
    remote 'tar -czf - -C /var/SaaS zapret2' >"$install_backup"
    chmod 600 "$install_backup"
  fi
  prune_backups
  echo "Backup saved under $BACKUP_DIR (private, gitignored)."
}

find_appmgr_slots() {
  local listing nfq='' watcher='' free=()
  # Variables and substitutions in this string belong to the router shell.
  # shellcheck disable=SC2016
  listing="$(remote 'i=1; while [ $i -le 16 ]; do n=`csmconf -g /appmgr:$i/name 2>/dev/null`; echo "$i:$n"; i=`expr $i + 1`; done' | tr -d '\r')"
  while IFS=: read -r slot name; do
    [[ "$name" == zapret2 ]] && nfq="$slot"
    [[ "$name" == zapret2-rules ]] && watcher="$slot"
    [[ -z "$name" ]] && free+=("$slot")
  done <<<"$listing"
  [[ -n "$nfq" ]] || { ((${#free[@]} >= 1)) || return 1; nfq="${free[0]}"; free=("${free[@]:1}"); }
  [[ -n "$watcher" ]] || { ((${#free[@]} >= 1)) || return 1; watcher="${free[0]}"; }
  printf '%s %s\n' "$nfq" "$watcher"
}

register_autostart() {
  local nfq_slot="$1" watch_slot="$2"
  remote "csmconf -s /appmgr:$nfq_slot/name zapret2; csmconf -s /appmgr:$nfq_slot/path /var/SaaS/zapret2/run.sh; csmconf -s /appmgr:$nfq_slot/argument start; csmconf -s /appmgr:$nfq_slot/auto_start 1; csmconf -s /appmgr:$nfq_slot/crash_start 1"
  remote "csmconf -s /appmgr:$watch_slot/name zapret2-rules; csmconf -s /appmgr:$watch_slot/path /var/SaaS/zapret2/watch-rules.sh; csmconf -s /appmgr:$watch_slot/argument start; csmconf -s /appmgr:$watch_slot/auto_start 1; csmconf -s /appmgr:$watch_slot/crash_start 1; csmctl savecfg"
  remote "printf 'NFQWS_SLOT=%s\\nWATCH_SLOT=%s\\n' '$nfq_slot' '$watch_slot' > /var/SaaS/zapret2/appmgr-slots"
}

start_without_reboot() {
  remote '/var/SaaS/zapret2/run.sh start >/var/tmp/zapret2.log 2>&1 & sleep 2; /var/SaaS/zapret2/watch-rules.sh start >/var/tmp/zapret2-rules.log 2>&1 & sleep 2'
}

verify() {
  # Variables and substitutions in this string belong to the router shell.
  # shellcheck disable=SC2016
  remote 'test -x /var/SaaS/zapret2/nfqws2; . /var/SaaS/zapret2/lib.sh; p=`cat /var/tmp/zapret2-nfqws.pid 2>/dev/null`; pid_matches "$p" /var/SaaS/zapret2/nfqws2; p=`cat /var/tmp/zapret2-watch.pid 2>/dev/null`; pid_matches "$p" /var/SaaS/zapret2/watch-rules.sh; iptables -t mangle -C POSTROUTING -o "$WAN" -j Z2OUT; iptables -t mangle -C FORWARD -i "$WAN" -j Z2IN; iptables -t mangle -C INPUT -i "$WAN" -j Z2IN' \
    || die 40 'installed service verification failed'
  remote '/var/SaaS/zapret2/status.sh'
  echo 'Verification passed. Generate client traffic and confirm counters increase.'
}

wait_after_reboot() {
  echo 'Waiting for SSH to disappear...'
  local i
  i=30
  while (( i-- > 0 )); do port_open || break; sleep 2; done
  echo 'Waiting for SSH to return...'
  i=90
  while (( i-- > 0 )); do port_open && { sleep 5; verify; return; }; sleep 2; done
  die 41 'router did not return to SSH after reboot'
}

install_zapret2() {
  preflight_install
  local wan slots nfq_slot watch_slot
  wan="$(detect_wan)"; slots="$(find_appmgr_slots)" || die 36 'two free/owned appmgr slots are required'
  read -r nfq_slot watch_slot <<<"$slots"
  echo "Plan: WAN=$wan appmgr=($nfq_slot,$watch_slot) version=$PROJECT_VERSION IPv6=$IPV6_ENABLED"
  (( DRY_RUN )) && { echo 'Dry run: no changes made.'; return; }
  backup_router
  upload_payload
  remote "test \"\`cat /var/tmp/zapret2-install/zapret2/VERSION\`\" = '$PROJECT_VERSION'; /var/tmp/zapret2-install/zapret2/nfqws2 --version >/dev/null" || die 23 'staged payload compatibility check failed'
  remote '/var/SaaS/zapret2/stop.sh 2>/dev/null || true; rm -rf /var/SaaS/zapret2.old; test ! -d /var/SaaS/zapret2 || mv /var/SaaS/zapret2 /var/SaaS/zapret2.old; mkdir -p /var/SaaS/zapret2; cp -f /var/tmp/zapret2-install/zapret2/* /var/SaaS/zapret2/; chmod 755 /var/SaaS/zapret2/*.sh /var/SaaS/zapret2/nfqws2; rm -rf /var/tmp/zapret2-install' \
    || { remote 'rm -rf /var/SaaS/zapret2; test ! -d /var/SaaS/zapret2.old || mv /var/SaaS/zapret2.old /var/SaaS/zapret2'; die 24 'transaction failed; previous directory restored'; }
  remote "printf 'WAN=%s\\nQNUM=200\\nMARK=0x40000000\\nENABLE_IPV6=%s\\n' '$wan' '$IPV6_ENABLED' > /var/SaaS/zapret2/config"
  register_autostart "$nfq_slot" "$watch_slot" || { remote 'rm -rf /var/SaaS/zapret2; test ! -d /var/SaaS/zapret2.old || mv /var/SaaS/zapret2.old /var/SaaS/zapret2'; die 37 'appmgr registration failed; files restored'; }
  if (( NO_REBOOT )); then
    start_without_reboot; verify
    echo 'WARNING: --no-reboot used; persistence has not been tested in this run.'
  else
    remote 'reboot' >/dev/null 2>&1 || true
    wait_after_reboot
  fi
  remote 'rm -rf /var/SaaS/zapret2.old' || true
}

status() { remote '/var/SaaS/zapret2/status.sh 2>/dev/null || { echo "zapret2 is not installed"; exit 1; }'; }

uninstall_zapret2() {
  remote 'test -d /var/SaaS/zapret2' || { echo 'zapret2 is already absent.'; return; }
  echo 'Plan: stop services, remove owned appmgr slots/rules and /var/SaaS/zapret2.'
  (( DRY_RUN )) && { echo 'Dry run: no changes made.'; return; }
  backup_router
  local slots nfq_slot watch_slot
  slots="$(remote 'cat /var/SaaS/zapret2/appmgr-slots 2>/dev/null || true')"
  nfq_slot="$(awk -F= '$1=="NFQWS_SLOT"{print $2}' <<<"$slots")"
  watch_slot="$(awk -F= '$1=="WATCH_SLOT"{print $2}' <<<"$slots")"
  remote '/var/SaaS/zapret2/stop.sh 2>/dev/null || true'
  if [[ "$watch_slot" =~ ^[0-9]+$ ]]; then
    remote "test \"\`csmconf -g /appmgr:$watch_slot/name 2>/dev/null\`\" != zapret2-rules || csmconf -d /appmgr:$watch_slot" || true
  fi
  if [[ "$nfq_slot" =~ ^[0-9]+$ ]]; then
    remote "test \"\`csmconf -g /appmgr:$nfq_slot/name 2>/dev/null\`\" != zapret2 || csmconf -d /appmgr:$nfq_slot" || true
  fi
  remote 'csmctl savecfg; rm -rf /var/SaaS/zapret2 /var/SaaS/zapret2.old'
  (( NO_REBOOT )) || { remote 'reboot' >/dev/null 2>&1 || true; echo 'Router is rebooting.'; }
}

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

command -v ssh >/dev/null || die 10 'ssh client not found'
command -v nc >/dev/null || die 10 'nc not found'
start_log
case "$ACTION" in
  diagnose) diagnose ;;
  install) install_zapret2 ;;
  status) status ;;
  verify) verify ;;
  uninstall) uninstall_zapret2 ;;
  *) usage; die 2 "unknown command: $ACTION" ;;
esac
