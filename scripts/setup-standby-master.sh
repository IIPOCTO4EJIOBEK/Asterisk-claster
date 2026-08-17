#!/bin/bash
#
# setup-standby-master.sh — резервный мастер (тёплый резерв).
#
# Проблема, которую решает. Мастер — единственная точка управления: при его
# отказе звонки идут, но завести номер, поправить IVR или пересобрать
# конфиги телефонов негде. Восстановление из бэкапа занимает 30-60 минут.
#
# Резервный мастер — это узел, который:
#   - состоит в Galera и потому имеет ВСЮ базу в актуальном состоянии;
#   - имеет установленный FreePBX той же версии;
#   - держит Asterisk и веб-интерфейс ОСТАНОВЛЕННЫМИ, пока не понадобится.
#
# При отказе основного мастера он поднимается одной командой и уже содержит
# все номера, диалплан, настройки модулей и данные Endpoint Manager —
# восстанавливать нечего, всё приехало репликацией.
#
# Режимы:
#   --prepare   подготовить узел как резервный (Asterisk выключен)
#   --status    показать готовность к переключению
#   --promote   поднять резерв в роли мастера
#   --demote    вернуть в режим ожидания (после возврата основного)
#
# Пример:
#   ./scripts/setup-standby-master.sh --prepare \
#       --node-name=rostov-standby --node-ip=10.1.10.112 \
#       --master-ip=10.1.10.111 --master-node-name=rostov \
#       --peers=10.1.10.111,10.1.10.112,10.4.3.6 \
#       --sst-pass='...' --rt-pass='...'
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env /etc/asterisk-cluster/cluster.env

MODE=""
ASSUME_YES=0

for arg in "$@"; do
  case $arg in
    --prepare) MODE=prepare ;;
    --status)  MODE=status ;;
    --promote) MODE=promote ;;
    --demote)  MODE=demote ;;
    --node-name=*)        NODE_NAME="${arg#*=}" ;;
    --node-ip=*)          NODE_IP="${arg#*=}" ;;
    --master-ip=*)        MASTER_IP="${arg#*=}" ;;
    --master-node-name=*) MASTER_NODE_NAME="${arg#*=}" ;;
    --peers=*)            PEERS="${arg#*=}" ;;
    --cluster-name=*)     CLUSTER_NAME="${arg#*=}" ;;
    --sst-pass=*)         SST_PASS="${arg#*=}" ;;
    --rt-pass=*)          RT_PASS="${arg#*=}" ;;
    --db-name=*)          DB_NAME="${arg#*=}" ;;
    --yes|-y)             ASSUME_YES=1 ;;
    -h|--help)            sed -n '2,32p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

[ -n "$MODE" ] || die "Укажите режим: --prepare, --status, --promote или --demote"
require_root
: "${DB_NAME:=asterisk}"
STANDBY_MARK=/etc/asterisk-cluster/standby-master

#=============================================================================
case "$MODE" in
#=============================================================================
prepare)
  : "${NODE_NAME:?--node-name обязателен}"
  : "${NODE_IP:?--node-ip обязателен}"
  : "${MASTER_IP:?--master-ip обязателен}"
  : "${PEERS:?--peers обязателен}"
  : "${SST_PASS:?--sst-pass обязателен}"
  : "${RT_PASS:?--rt-pass обязателен}"
  : "${MASTER_NODE_NAME:=master}"
  : "${CLUSTER_NAME:=asterisk_prod}"
  require_node_name "$NODE_NAME"
  require_ipv4 --node-ip "$NODE_IP"

  cat <<EOF

  Узел $NODE_NAME ($NODE_IP) станет РЕЗЕРВНЫМ мастером.

  Он войдёт в кластер и получит всю базу, но Asterisk и веб-интерфейс
  будут остановлены и отключены из автозапуска. Телефоны на него не
  регистрируются, вызовы не обслуживаются — узел ждёт своего часа.

  Требование: FreePBX и Asterisk должны быть уже установлены той же
  версии, что на основном мастере.

EOF
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Продолжить? [y/N] " a
    case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено." ;; esac
  fi

  command -v asterisk >/dev/null 2>&1 || die "Asterisk не установлен.
Установите FreePBX той же версии, что на мастере, затем повторите."
  command -v fwconsole >/dev/null 2>&1 || warn "fwconsole не найден — FreePBX не обнаружен."

  step "[1/4] Присоединение к кластеру"
  # Узел вступает как обычный член Galera: база приедет через SST.
  "$REPO_ROOT/scripts/clone-node.sh" \
    --node-name="$NODE_NAME" --node-ip="$NODE_IP" \
    --master-ip="$MASTER_IP" --master-node-name="$MASTER_NODE_NAME" \
    --peers="$PEERS" --cluster-name="$CLUSTER_NAME" \
    --sst-pass="$SST_PASS" --rt-pass="$RT_PASS" \
    --db-name="$DB_NAME" --yes

  step "[2/4] Остановка обслуживания"
  # Резерв не должен принимать регистрации: иначе телефоны разойдутся
  # между двумя мастерами, а вызовы начнут теряться.
  systemctl stop asterisk 2>/dev/null || true
  systemctl disable asterisk >/dev/null 2>&1 || true
  for svc in freepbx apache2 httpd nginx; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
  info "Asterisk и веб-интерфейс остановлены и убраны из автозапуска"

  step "[3/4] Пометка роли"
  install -d -m 0750 /etc/asterisk-cluster
  cat >"$STANDBY_MARK" <<EOF
# Узел подготовлен как резервный мастер: setup-standby-master.sh --prepare
# $(date -Is)
STANDBY_FOR=$MASTER_NODE_NAME
STANDBY_FOR_IP=$MASTER_IP
PREPARED_AT=$(date -Is)
EOF
  chmod 0640 "$STANDBY_MARK"

  step "[4/4] Проверка"
  SIZE="$(cluster_size)"
  EXT="$(mysql_local -e "SELECT COUNT(*) FROM \`$DB_NAME\`.users;" 2>/dev/null || echo '?')"
  info "Размер кластера: $SIZE, добавочных в базе: $EXT"

  cat <<EOF

$(printf '%s' "$C_GRN")Резервный мастер $NODE_NAME готов.$(printf '%s' "$C_OFF")

База синхронизируется непрерывно. Asterisk выключен — узел не обслуживает
вызовы и не принимает регистрации.

При отказе основного мастера:
    $0 --promote

Проверять готовность (стоит делать регулярно):
    $0 --status

EOF
  ;;

#=============================================================================
status)
  [ -f "$STANDBY_MARK" ] || die "Этот узел не подготовлен как резервный мастер."
  # shellcheck disable=SC1090
  . "$STANDBY_MARK"

  step "Резервный мастер: готовность"
  info "Резерв для: ${STANDBY_FOR:-?} (${STANDBY_FOR_IP:-?})"
  info "Подготовлен: ${PREPARED_AT:-?}"

  RC=0
  SIZE="$(cluster_size)"
  STATE="$(wsrep_status wsrep_local_state_comment)"
  if [ "$STATE" = "Synced" ]; then
    info "Репликация: Synced, узлов в кластере $SIZE"
  else
    warn "Репликация: $STATE — база НЕ актуальна, переключение опасно"
    RC=1
  fi

  EXT="$(mysql_local -e "SELECT COUNT(*) FROM \`$DB_NAME\`.users;" 2>/dev/null || echo '?')"
  info "Добавочных в базе: $EXT"

  if systemctl is-active --quiet asterisk; then
    warn "Asterisk ЗАПУЩЕН на резервном узле — это конфликт с основным мастером"
    RC=1
  else
    info "Asterisk остановлен (правильно для резерва)"
  fi

  if command -v asterisk >/dev/null 2>&1; then
    info "Версия Asterisk: $(asterisk -V 2>/dev/null)"
  fi

  # Доступен ли основной мастер
  if [ -n "${STANDBY_FOR_IP:-}" ] && command -v nc >/dev/null 2>&1; then
    if nc -z -w3 "$STANDBY_FOR_IP" 5060 2>/dev/null; then
      info "Основной мастер отвечает — переключение не требуется"
    else
      warn "Основной мастер ${STANDBY_FOR_IP} не отвечает на 5060"
    fi
  fi

  printf '\n'
  [ "$RC" = 0 ] && log "Готов к переключению." || warn "К переключению НЕ готов, см. выше."
  exit "$RC"
  ;;

#=============================================================================
promote)
  [ -f "$STANDBY_MARK" ] || die "Этот узел не подготовлен как резервный мастер."
  # shellcheck disable=SC1090
  . "$STANDBY_MARK"

  STATE="$(wsrep_status wsrep_local_state_comment)"
  [ "$STATE" = "Synced" ] || die "Узел не в состоянии Synced ($STATE).
Поднимать мастер с неактуальной базой нельзя — сначала дождитесь синхронизации."

  cat <<EOF

  ВНИМАНИЕ: узел будет поднят в роли мастера.

  Убедитесь, что основной мастер ${STANDBY_FOR:-?} (${STANDBY_FOR_IP:-?})
  ДЕЙСТВИТЕЛЬНО не работает. Два одновременно работающих мастера —
  это два веб-интерфейса, пишущих в одну базу, и телефоны, разошедшиеся
  между ними.

EOF
  if [ "${STANDBY_FOR_IP:-}" ] && command -v nc >/dev/null 2>&1; then
    if nc -z -w3 "$STANDBY_FOR_IP" 5060 2>/dev/null; then
      warn "Основной мастер ОТВЕЧАЕТ на 5060. Похоже, он жив."
    fi
  fi

  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Поднять этот узел как мастер? [y/N] " a
    case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено." ;; esac
  fi

  step "Запуск обслуживания"
  systemctl enable asterisk >/dev/null 2>&1 || true
  systemctl start asterisk
  for _ in $(seq 1 30); do asterisk_running && break; sleep 1; done
  asterisk_running || die "Asterisk не запустился: journalctl -u asterisk -n 100"

  for svc in apache2 httpd nginx freepbx; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\."; then
      systemctl enable "$svc" >/dev/null 2>&1 || true
      systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done
  command -v fwconsole >/dev/null 2>&1 && fwconsole start >/dev/null 2>&1 || true

  sed -i 's/^# PROMOTED.*//' "$STANDBY_MARK" 2>/dev/null || true
  printf '# PROMOTED_AT=%s\n' "$(date -Is)" >>"$STANDBY_MARK"

  EP="$(asterisk -rx 'pjsip show endpoints' 2>/dev/null | grep -c '^ *Endpoint:' || echo 0)"
  log "Узел поднят как мастер. Endpoint'ов: $EP"

  cat <<EOF

Осталось сделать вручную — переключение зависит от вашей сети:

  1. Направить телефоны на этот узел. Варианты:
     - перенести IP основного мастера на этот узел (если сеть позволяет);
     - обновить резервный сервер в шаблоне Endpoint Manager и пересобрать
       конфиги: fwconsole endpoint rebuildall
  2. Проверить транки: asterisk -rx "pjsip show registrations"
  3. Обновить межузловые транки на площадках, если сменился адрес мастера:
     ./scripts/make-node-trunks.sh --peers-map=...

Когда основной мастер вернётся — НЕ включайте на нём Asterisk сразу.
Сначала переведите этот узел обратно в резерв:
    $0 --demote

EOF
  ;;

#=============================================================================
demote)
  [ -f "$STANDBY_MARK" ] || die "Этот узел не помечен как резервный мастер."
  warn "Узел вернётся в режим ожидания: Asterisk и веб-интерфейс будут остановлены."
  warn "Убедитесь, что основной мастер уже обслуживает вызовы."
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Продолжить? [y/N] " a
    case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено." ;; esac
  fi

  systemctl stop asterisk 2>/dev/null || true
  systemctl disable asterisk >/dev/null 2>&1 || true
  for svc in freepbx apache2 httpd nginx; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
  done
  printf '# DEMOTED_AT=%s\n' "$(date -Is)" >>"$STANDBY_MARK"
  log "Узел вернулся в режим резерва. База продолжает синхронизироваться."
  ;;
esac
