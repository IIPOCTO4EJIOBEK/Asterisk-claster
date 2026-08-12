#!/bin/bash
#
# update-peers.sh — обновляет список узлов кластера на ЭТОМ узле.
#
# Зачем. wsrep_cluster_address на каждом узле обязан содержать все узлы
# кластера. Если при добавлении пятой площадки не обновить конфигурацию
# четырёх предыдущих, всё работает ровно до первого одновременного
# рестарта: узлы знают только про мастер, который перезагружается вместе
# с ними, и кластер не собирается.
#
# Скрипт делает это безопасно: правит конфигурацию, при необходимости
# перезапускает MariaDB и дожидается состояния Synced — но только если
# кластер переживёт уход этого узла.
#
#   ./scripts/update-peers.sh --peers=10.1.10.111,10.4.3.6,10.5.1.4
#   ./scripts/update-peers.sh --peers=... --restart      # с перезапуском
#
# Параметры:
#   --peers=      полный список IP всех узлов через запятую
#   --restart     применить сразу (перезапуск MariaDB)
#   --force       перезапустить, даже если кластер потеряет кворум
#   --yes         без вопросов
#
# ПОРЯДОК: обходите узлы ПО ОДНОМУ, дожидаясь Synced перед переходом к
# следующему. Одновременный перезапуск нескольких узлов роняет кластер.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env /etc/asterisk-cluster/cluster.env

DO_RESTART=0
FORCE=0
ASSUME_YES=0
NEW_PEERS=""

for arg in "$@"; do
  case $arg in
    --peers=*)  NEW_PEERS="${arg#*=}" ;;
    --restart)  DO_RESTART=1 ;;
    --force)    FORCE=1 ;;
    --yes|-y)   ASSUME_YES=1 ;;
    -h|--help)  sed -n '2,26p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
: "${NEW_PEERS:?--peers обязателен}"
: "${NODE_IP:?Не удалось определить IP этого узла. Проверьте /etc/asterisk-cluster/cluster.env}"
: "${NODE_NAME:?Не удалось определить имя этого узла.}"
: "${CLUSTER_NAME:=asterisk_prod}"
: "${SST_USER:=sst_user}"
: "${SST_PASS:?Пароль SST не найден в cluster.env}"

# Проверяем каждый адрес и обязательное присутствие себя.
IFS=',' read -r -a PEER_ARR <<<"$NEW_PEERS"
for p in "${PEER_ARR[@]}"; do
  [ -n "$p" ] || continue
  require_ipv4 --peers "$p"
done
case ",$NEW_PEERS," in
  *",$NODE_IP,"*) ;;
  *) die "IP этого узла ($NODE_IP) отсутствует в --peers.
Список должен быть полным и включать все узлы, в том числе текущий." ;;
esac

CNF_DIR=/etc/mysql/mariadb.conf.d
[ -d "$CNF_DIR" ] || CNF_DIR=/etc/mysql/conf.d
CNF="$CNF_DIR/60-galera.cnf"
[ -f "$CNF" ] || die "Не найден $CNF — узел не настроен под Galera."

OLD_PEERS="$(sed -n 's/^wsrep_cluster_address="gcomm:\/\/\(.*\)"/\1/p' "$CNF" | head -1)"
info "Узел:  $NODE_NAME ($NODE_IP)"
info "Было:  ${OLD_PEERS:-(не задано)}"
info "Стало: $NEW_PEERS"

if [ "$OLD_PEERS" = "$NEW_PEERS" ]; then
  log "Список узлов уже актуален — менять нечего."
  exit 0
fi

#-----------------------------------------------------------------------------
step "Обновление конфигурации"
#-----------------------------------------------------------------------------
WSREP_SLAVE_THREADS="$(sed -n 's/^wsrep_slave_threads=\(.*\)/\1/p' "$CNF" | head -1)"
[ -n "$WSREP_SLAVE_THREADS" ] || { WSREP_SLAVE_THREADS="$(nproc)"; [ "$WSREP_SLAVE_THREADS" -gt 8 ] && WSREP_SLAVE_THREADS=8; }
GCACHE_SIZE="$(sed -n 's/.*gcache.size=\([0-9A-Za-z]*\).*/\1/p' "$CNF" | head -1)"
[ -n "$GCACHE_SIZE" ] || GCACHE_SIZE=1G

PEERS="$NEW_PEERS"
export PEERS NODE_IP NODE_NAME CLUSTER_NAME SST_USER SST_PASS \
       WSREP_SLAVE_THREADS GCACHE_SIZE
render_tpl "$REPO_ROOT/config/galera/60-galera.cnf.tpl" "$CNF" 0640

# Держим cluster.env в согласии с конфигурацией, иначе следующий скрипт
# возьмёт устаревший список.
ENVFILE=/etc/asterisk-cluster/cluster.env
if [ -f "$ENVFILE" ]; then
  backup_file "$ENVFILE"
  if grep -q '^PEERS=' "$ENVFILE"; then
    sed -i "s|^PEERS=.*|PEERS=$NEW_PEERS|" "$ENVFILE"
  else
    printf 'PEERS=%s\n' "$NEW_PEERS" >>"$ENVFILE"
  fi
  info "PEERS обновлён в $ENVFILE"
fi

log "Конфигурация обновлена."

#-----------------------------------------------------------------------------
if [ "$DO_RESTART" != 1 ]; then
  cat <<EOF

Новый список вступит в силу при следующем перезапуске MariaDB.
Это безопасно отложить: работающий кластер продолжает использовать уже
установленные соединения.

Чтобы применить сейчас:
    $0 --peers=$NEW_PEERS --restart

Обходите узлы ПО ОДНОМУ, дожидаясь Synced перед переходом к следующему.

EOF
  exit 0
fi

#-----------------------------------------------------------------------------
step "Проверка кворума перед перезапуском"
#-----------------------------------------------------------------------------
SIZE="$(cluster_size)"
STATE="$(wsrep_status wsrep_local_state_comment)"
info "Размер кластера: $SIZE, состояние: $STATE"

if [ "$SIZE" -le 1 ]; then
  warn "Этот узел — единственный в кластере."
  warn "Перезапуск остановит обслуживание до его возвращения."
elif [ "$STATE" != "Synced" ]; then
  warn "Узел не в состоянии Synced ($STATE) — перезапускать рано."
fi

# Кворум после ухода узла: оставшихся должно быть больше половины исходного.
REMAIN=$((SIZE - 1))
NEED=$(( SIZE / 2 + 1 ))
if [ "$SIZE" -gt 1 ] && [ "$REMAIN" -lt "$NEED" ]; then
  warn "После ухода этого узла останется $REMAIN из $SIZE — меньше кворума ($NEED)."
  warn "Оставшиеся узлы перейдут в non-Primary и перестанут обслуживать запросы."
  if [ "$FORCE" != 1 ]; then
    die "Прерываю. Дождитесь возвращения других узлов либо используйте --force,
если осознанно идёте на остановку кластера."
  fi
  warn "Продолжаю по --force."
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf '\n'
  read -r -p "Перезапустить MariaDB на $NODE_NAME? [y/N] " a
  case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено. Конфигурация уже обновлена, примените позже." ;; esac
fi

#-----------------------------------------------------------------------------
step "Перезапуск и ожидание синхронизации"
#-----------------------------------------------------------------------------
systemctl restart mariadb &
RESTART_PID=$!

SYNCED=0
for i in $(seq 1 300); do
  if mysqladmin ping >/dev/null 2>&1; then
    ST="$(wsrep_status wsrep_local_state_comment)"
    case "$ST" in
      Synced) SYNCED=1; break ;;
      *) [ $((i % 15)) -eq 0 ] && info "  ... $ST (${i}s)" ;;
    esac
  else
    [ $((i % 30)) -eq 0 ] && info "  ... MariaDB поднимается (${i}s)"
  fi
  sleep 1
done
wait "$RESTART_PID" 2>/dev/null || true

NEW_SIZE="$(cluster_size)"
NEW_STATE="$(wsrep_status wsrep_local_state_comment)"
if [ "$SYNCED" = 1 ]; then
  log "Узел синхронизирован. Размер кластера: $NEW_SIZE"
else
  warn "Узел не достиг Synced за 300 с (состояние: $NEW_STATE)."
  warn "Смотрите: journalctl -u mariadb -n 100 --no-pager"
  warn "НЕ переходите к следующему узлу, пока этот не синхронизируется."
  exit 1
fi

# Asterisk мог потерять realtime на время перезапуска БД.
if asterisk_running; then
  asterisk -rx "module reload res_odbc.so" >/dev/null 2>&1 || true
  EP="$(asterisk -rx 'pjsip show endpoints' 2>/dev/null | grep -c '^ *Endpoint:' || echo 0)"
  info "Asterisk видит endpoint'ов: $EP"
fi

cat <<EOF

Узел $NODE_NAME обновлён и синхронизирован.

Переходите к следующему узлу — по одному, с той же командой и тем же
списком peers. Перед каждым следующим убедитесь, что текущий в Synced:

    mysql -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"

EOF
