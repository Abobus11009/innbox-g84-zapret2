#!/usr/bin/env bash
set -Eeuo pipefail

ROUTER_HOST="${G84_HOST:-192.168.1.1}"
ROUTER_USER="${G84_USER:-superadmin}"
TARGET="${ROUTER_USER}@${ROUTER_HOST}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/g84-zapret2-payload.tar.gz"
BACKUP_DIR="$SCRIPT_DIR/backups"
NO_REBOOT=0

SSH_BASE=(
  -o "KexAlgorithms=+diffie-hellman-group1-sha1"
  -o "HostKeyAlgorithms=+ssh-rsa"
  -o "ConnectTimeout=8"
)

usage() {
  cat <<'EOF'
Использование:
  ./g84-zapret2.sh diagnose [--host IP]
  ./g84-zapret2.sh install  [--host IP] [--no-reboot]
  ./g84-zapret2.sh status   [--host IP]
  ./g84-zapret2.sh uninstall [--host IP] [--no-reboot]

Пароль не хранится в скрипте: SSH запросит его при подключении.
Install и uninstall по умолчанию перезагружают роутер для проверки автозапуска.
EOF
}

die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

remote() { ssh "${SSH_BASE[@]}" "$TARGET" "$@"; }

diagnose() {
  printf '%s\n' '=== Модель, ядро, архитектура и права ==='
  remote 'uname -a; sed -n "1,24p" /proc/cpuinfo; busybox id 2>/dev/null || true'
  printf '%s\n' '=== Файловые системы и свободное место ==='
  remote 'df -h; mount'
  printf '%s\n' '=== Netfilter / NFQUEUE ==='
  remote 'iptables --version; ip6tables --version 2>/dev/null || true; grep -E "NFQUEUE|QUEUE" /proc/net/ip_tables_targets 2>/dev/null || true; grep -Ei "queue|nfnetlink|netfilter" /proc/modules 2>/dev/null || true'
  printf '%s\n' '=== Аппаратное ускорение ==='
  remote 'grep -Ei "hnat|ppe|flow|ecnt" /proc/modules 2>/dev/null || true; find /proc /sys -maxdepth 3 -iname "*hnat*" -o -iname "*offload*" 2>/dev/null; true'
  printf '%s\n' '=== Утилиты и автозапуск ==='
  remote 'for x in sh busybox iptables ip6tables csmconf csmctl appmgrcmd tar wget; do command -v "$x" 2>/dev/null || true; done; echo appmgr:; csmconf -g /appmgr:1/name 2>/dev/null || true; csmconf -g /appmgr:2/name 2>/dev/null || true'
}

status() {
  remote '/var/SaaS/zapret2/status.sh 2>/dev/null || { echo "zapret2 не установлен"; exit 1; }'
}

backup_router() {
  mkdir -p "$BACKUP_DIR"
  local stamp config_backup install_backup
  stamp="$(date +%Y%m%d-%H%M%S)"
  config_backup="$BACKUP_DIR/g84-config-$stamp.xml"
  install_backup="$BACKUP_DIR/g84-zapret2-$stamp.tar.gz"
  remote "csmconf -D /var/tmp/g84-config-$stamp.xml"
  remote "cat /var/tmp/g84-config-$stamp.xml; rm -f /var/tmp/g84-config-$stamp.xml" >"$config_backup"
  if remote 'test -d /var/SaaS/zapret2'; then
    remote 'tar -czf - -C /var/SaaS zapret2' >"$install_backup"
    printf 'Резервные копии: %s и %s\n' "$config_backup" "$install_backup"
  else
    printf 'Резервная копия конфигурации: %s\n' "$config_backup"
  fi
}

preflight_install() {
  local available_kib
  [[ -f "$PAYLOAD" ]] || die "рядом со скриптом нет $(basename "$PAYLOAD")"
  remote 'grep -q EN7528 /proc/cpuinfo && grep -q en751221 /proc/cpuinfo' || die 'это не проверенная платформа Innbox G84 / EcoNet EN7528'
  remote 'grep -q NFQUEUE /proc/net/ip_tables_targets' || die 'ядро не сообщает о поддержке NFQUEUE'
  remote 'test -d /var/SaaS && test -w /var/SaaS' || die '/var/SaaS отсутствует или недоступен для записи'
  remote 'awk "/^Uid:/{exit \$2}" /proc/self/status' || die 'SSH-сессия не имеет root-прав'
  available_kib="$(remote 'df -k /var/SaaS' | awk 'NR==2 {print $4}')"
  [[ "$available_kib" =~ ^[0-9]+$ && "$available_kib" -ge 700 ]] || die 'на /var/SaaS меньше 700 КиБ свободного места'
}

register_autostart() {
  remote 'csmconf -s /appmgr:1/name zapret2; csmconf -s /appmgr:1/path /var/SaaS/zapret2/run.sh; csmconf -s /appmgr:1/argument start; csmconf -s /appmgr:1/auto_start 1; csmconf -s /appmgr:1/crash_start 1'
  remote 'csmconf -s /appmgr:2/name zapret2-rules; csmconf -s /appmgr:2/path /var/SaaS/zapret2/watch-rules.sh; csmconf -s /appmgr:2/argument start; csmconf -s /appmgr:2/auto_start 1; csmconf -s /appmgr:2/crash_start 1; csmctl savecfg'
}

install_zapret2() {
  preflight_install
  backup_router
  printf 'Передача проверенного MIPS little-endian комплекта...\n'
  remote 'rm -rf /var/tmp/zapret2-install && mkdir -p /var/tmp/zapret2-install && tar -xzf - -C /var/tmp/zapret2-install' <"$PAYLOAD"
  remote 'test -x /var/tmp/zapret2-install/zapret2/nfqws2 && /var/tmp/zapret2-install/zapret2/nfqws2 --version >/dev/null'
  remote '/var/SaaS/zapret2/stop.sh 2>/dev/null || true'
  remote 'mkdir -p /var/SaaS/zapret2 && cp -f /var/tmp/zapret2-install/zapret2/* /var/SaaS/zapret2/ && chmod 755 /var/SaaS/zapret2/*.sh /var/SaaS/zapret2/nfqws2 && rm -rf /var/tmp/zapret2-install'
  register_autostart
  printf 'Установка завершена, конфигурация автозапуска сохранена.\n'
  finish_change
}

uninstall_zapret2() {
  backup_router
  remote '/var/SaaS/zapret2/stop.sh 2>/dev/null || true; csmconf -g /appmgr:2/name 2>/dev/null | grep -q "^zapret2-rules$" && csmconf -d /appmgr:2 || true; csmconf -g /appmgr:1/name 2>/dev/null | grep -q "^zapret2$" && csmconf -d /appmgr:1 || true; csmctl savecfg; rm -rf /var/SaaS/zapret2'
  printf 'zapret2 и его правила автозапуска удалены; резервная копия сохранена.\n'
  finish_change
}

finish_change() {
  if (( NO_REBOOT )); then
    if [[ "$ACTION" == install ]]; then
      printf 'Перезагрузка пропущена; запускаю установленную версию сейчас.\n'
      remote 'killall nfqws2 2>/dev/null || true; killall watch-rules.sh 2>/dev/null || true; /var/SaaS/zapret2/run.sh start >/var/tmp/zapret2.log 2>&1 & /var/SaaS/zapret2/watch-rules.sh start >/var/tmp/zapret2-rules.log 2>&1 & sleep 2; ps | grep nfqws2 | grep -v grep >/dev/null'
      status
    else
      printf 'Перезагрузка пропущена; удаление уже применено.\n'
    fi
    return
  fi
  printf 'Роутер перезагружается. Связь обычно вернётся через 1–3 минуты.\n'
  remote 'reboot' >/dev/null 2>&1 || true
}

[[ $# -ge 1 ]] || { usage; exit 1; }
ACTION="$1"; shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) [[ $# -ge 2 ]] || die 'после --host нужен IP'; ROUTER_HOST="$2"; TARGET="${ROUTER_USER}@${ROUTER_HOST}"; shift 2 ;;
    --no-reboot) NO_REBOOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "неизвестный параметр: $1" ;;
  esac
done

command -v ssh >/dev/null || die 'не найден клиент ssh'
case "$ACTION" in
  diagnose) diagnose ;;
  install) install_zapret2 ;;
  status) status ;;
  uninstall) uninstall_zapret2 ;;
  *) usage; die "неизвестная команда: $ACTION" ;;
esac
