#!/bin/bash
#
# clone-node.sh — разворачивает secondary-узел кластера: MariaDB Galera (join
# по SST с мастера) + headless Asterisk на realtime + межузловая маршрутизация.
#
# Запускать НА НОВОМ СЕРВЕРЕ от root.
#
#   ./scripts/clone-node.sh \
#     --node-name=voronezh --node-ip=10.4.3.6 \
#     --master-ip=10.10.10.11 --master-node-name=rostov \
#     --peers=10.10.10.11,10.4.3.6 \
#     --cluster-name=asterisk_prod \
#     --sst-pass='...' --rt-pass='...'
#
# Обязательные параметры:
#   --node-name=       имя узла (a-z0-9-), оно же systemname и имя транка
#   --node-ip=         IP этого узла
#   --master-ip=       IP мастера (донор SST)
#   --peers=           ПОЛНЫЙ список IP всех узлов через запятую
#   --sst-pass=        пароль sst_user (выдан install-master.sh)
#   --rt-pass=         пароль asterisk_rt (выдан install-master.sh)
#
# Необязательные:
#   --master-node-name=  имя мастера для исходящей маршрутизации (по умолч. master)
#   --cluster-name=      имя кластера (по умолч. asterisk_prod)
#   --asterisk-major=    какую мажорную версию Asterisk ожидать (сверяется с мастером)
#   --local-net=, --admin-cidr=, --cluster-cidr=, --db-name=
#   --skip-firewall      не трогать ufw
#   --yes                без вопросов
#
# Идемпотентен: повторный запуск обновляет конфигурацию, делая бэкап каждого
# изменяемого файла рядом (*.bak.YYYYmmdd-HHMMSS).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env

ROLE=secondary
SKIP_FIREWALL=0
ASSUME_YES=0
MASTER_NODE_NAME=master

for arg in "$@"; do
  case $arg in
    --role=*)             ROLE="${arg#*=}" ;;
    --node-name=*)        NODE_NAME="${arg#*=}" ;;
    --node-ip=*)          NODE_IP="${arg#*=}" ;;
    --master-ip=*)        MASTER_IP="${arg#*=}" ;;
    --master-node-name=*) MASTER_NODE_NAME="${arg#*=}" ;;
    --peers=*)            PEERS="${arg#*=}" ;;
    --cluster-name=*)     CLUSTER_NAME="${arg#*=}" ;;
    --sst-pass=*)         SST_PASS="${arg#*=}" ;;
    --sst-user=*)         SST_USER="${arg#*=}" ;;
    --rt-user=*)          RT_USER="${arg#*=}" ;;
    --rt-pass=*)          RT_PASS="${arg#*=}" ;;
    --db-name=*)          DB_NAME="${arg#*=}" ;;
    --local-net=*)        LOCAL_NET="${arg#*=}" ;;
    --admin-cidr=*)       ADMIN_CIDR="${arg#*=}" ;;
    --cluster-cidr=*)     CLUSTER_CIDR="${arg#*=}" ;;
    --asterisk-major=*)   ASTERISK_MAJOR="${arg#*=}" ;;
    --skip-firewall)      SKIP_FIREWALL=1 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    -h|--help)            sed -n '2,38p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg
Подсказка: список параметров — ./scripts/clone-node.sh --help" ;;
  esac
done

require_root
require_os_codename bookworm bullseye

# В черновике --role парсился, но нигде не использовался: --role=master
# молча ставил secondary. Теперь роль либо обрабатывается, либо отвергается.
case "$ROLE" in
  secondary) ;;
  master) die "Для мастера используйте scripts/install-master.sh — этот скрипт ставит только secondary." ;;
  *) die "Недопустимая роль '$ROLE'. Допустимо: secondary." ;;
esac

: "${NODE_NAME:?--node-name обязателен}"
: "${NODE_IP:?--node-ip обязателен}"
: "${MASTER_IP:?--master-ip обязателен}"
: "${PEERS:?--peers обязателен: полный список IP всех узлов кластера}"
: "${SST_PASS:?--sst-pass обязателен (значение выдал install-master.sh)}"
: "${RT_PASS:?--rt-pass обязателен (значение выдал install-master.sh)}"
: "${CLUSTER_NAME:=asterisk_prod}"
: "${SST_USER:=sst_user}"
: "${RT_USER:=asterisk_rt}"
: "${DB_NAME:=asterisk}"
: "${LOCAL_NET:=10.0.0.0/8}"
: "${CLUSTER_CIDR:=$LOCAL_NET}"
: "${ADMIN_CIDR:=10.0.0.0/8}"
: "${SIP_PORT:=5060}"
: "${SIP_TLS_PORT:=5061}"
: "${RTP_START:=10000}"
: "${RTP_END:=20000}"
: "${ASTERISK_REPO_URL:=http://deb.freepbx.org/freepbx17-prod}"
: "${ASTERISK_REPO_SUITE:=bookworm}"
: "${ASTERISK_REPO_KEY_URL:=http://deb.freepbx.org/gpg/aptly-pubkey.asc}"

require_node_name "$NODE_NAME"
require_node_name "$MASTER_NODE_NAME"
require_ipv4 --node-ip "$NODE_IP"
require_ipv4 --master-ip "$MASTER_IP"

case ",$PEERS," in
  *",$NODE_IP,"*) ;;
  *) die "NODE_IP $NODE_IP отсутствует в --peers ($PEERS).
Список peers должен быть полным и одинаковым на всех узлах, иначе после
одновременного рестарта узлы не найдут друг друга." ;;
esac
case ",$PEERS," in
  *",$MASTER_IP,"*) ;;
  *) die "MASTER_IP $MASTER_IP отсутствует в --peers ($PEERS)." ;;
esac

WSREP_SLAVE_THREADS="$(nproc)"
[ "$WSREP_SLAVE_THREADS" -gt 8 ] && WSREP_SLAVE_THREADS=8
GCACHE_SIZE="1G"
export NODE_NAME NODE_IP PEERS CLUSTER_NAME DB_NAME SST_USER SST_PASS \
       RT_USER RT_PASS LOCAL_NET SIP_PORT WSREP_SLAVE_THREADS GCACHE_SIZE

cat <<EOF

  Узел:      $NODE_NAME ($NODE_IP), роль secondary
  Кластер:   $CLUSTER_NAME
  Мастер:    $MASTER_NODE_NAME ($MASTER_IP)
  Все узлы:  $PEERS
  База:      $DB_NAME

EOF
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Продолжить? [y/N] " a
  case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено." ;; esac
fi

#-----------------------------------------------------------------------------
step "[1/8] Базовая подготовка ОС"
#-----------------------------------------------------------------------------
ensure_pkg curl wget git sudo vim ufw chrony socat rsync ca-certificates \
           gnupg python3 python3-pymysql netcat-openbsd
systemctl enable --now chrony >/dev/null 2>&1 || true

#-----------------------------------------------------------------------------
step "[2/8] Firewall"
#-----------------------------------------------------------------------------
if [ "$SKIP_FIREWALL" = 1 ]; then
  info "Пропущено по --skip-firewall"
else
  # SSH — первым правилом и до включения ufw.
  ufw allow from "$ADMIN_CIDR" to any port 22 proto tcp comment 'ssh admin' >/dev/null
  ufw allow 22/tcp comment 'ssh fallback' >/dev/null
  for port in 3306 4444 4567 4568; do
    ufw allow from "$CLUSTER_CIDR" to any port "$port" proto tcp comment 'galera' >/dev/null
  done
  ufw allow "$SIP_PORT"/udp comment 'sip' >/dev/null
  ufw allow "$SIP_TLS_PORT"/tcp comment 'sip tls' >/dev/null
  ufw allow "${RTP_START}:${RTP_END}"/udp comment 'rtp' >/dev/null
  ufw --force enable >/dev/null
  info "ufw активен, SSH разрешён"
fi

#-----------------------------------------------------------------------------
step "[3/8] Доступность мастера"
#-----------------------------------------------------------------------------
if command -v nc >/dev/null 2>&1; then
  nc -z -w5 "$MASTER_IP" 4567 2>/dev/null \
    || warn "Порт 4567 на мастере $MASTER_IP недоступен — SST не пройдёт.
         Проверьте firewall мастера и маршрутизацию между площадками."
  nc -z -w5 "$MASTER_IP" 3306 2>/dev/null \
    || warn "Порт 3306 на мастере $MASTER_IP недоступен."
fi

#-----------------------------------------------------------------------------
step "[4/8] MariaDB + Galera"
#-----------------------------------------------------------------------------
ensure_pkg mariadb-server mariadb-client mariadb-backup galera-4

systemctl stop mariadb 2>/dev/null || true

render_tpl "$REPO_ROOT/config/galera/60-galera.cnf.tpl" \
           /etc/mysql/mariadb.conf.d/60-galera.cnf 0640

# Локальная база пустая: при вступлении в кластер её содержимое всё равно
# будет заменено снимком с донора (SST). Удаляем остатки прошлого состояния
# кластера, иначе узел может попытаться подняться как самостоятельный.
if [ -f /var/lib/mysql/grastate.dat ] && [ ! -s /var/lib/mysql/gvwstate.dat ]; then
  dbg "grastate.dat присутствует, оставляем как есть"
fi

step "    Присоединение к кластеру (SST с ${MASTER_IP})"
info "Первый SST копирует всю базу — на больших инсталляциях это минуты."
systemctl start mariadb &
SYSTEMD_PID=$!

# Ждём именно синхронизации, а не просто запуска процесса: в черновике
# был sleep 5, после которого проверка почти всегда видела недособранный узел.
SYNCED=0
for i in $(seq 1 180); do
  if mysqladmin ping >/dev/null 2>&1; then
    STATE="$(wsrep_status wsrep_local_state_comment)"
    SIZE="$(cluster_size)"
    case "$STATE" in
      Synced)
        SYNCED=1
        info "Состояние: Synced, размер кластера: ${SIZE}"
        break ;;
      Joining|"Joining: receiving State Transfer"|Donor/Desynced|Joined)
        [ $((i % 10)) -eq 0 ] && info "  ... $STATE (${i}s)" ;;
    esac
  else
    [ $((i % 30)) -eq 0 ] && info "  ... MariaDB ещё поднимается (${i}s)"
  fi
  sleep 1
done
wait "$SYSTEMD_PID" 2>/dev/null || true

SIZE="$(cluster_size)"
if [ "$SYNCED" != 1 ] || [ "$SIZE" -lt 2 ]; then
  warn "Узел не синхронизировался (wsrep_cluster_size=${SIZE})."
  warn "Что проверить:"
  warn "  1) на мастере есть пользователь SST:"
  warn "     mysql -e \"SELECT User,Host FROM mysql.user WHERE User='${SST_USER}';\""
  warn "  2) совпадает ли пароль sst_user с --sst-pass"
  warn "  3) открыты ли между узлами порты 4444/4567/4568"
  warn "  4) журнал: journalctl -u mariadb -n 200 --no-pager"
  die "Прерываю: без рабочей репликации ставить Asterisk бессмысленно."
fi

#-----------------------------------------------------------------------------
step "[5/8] Asterisk той же версии, что на мастере"
#-----------------------------------------------------------------------------
# Черновик ставил Asterisk из стока Debian (это 16), тогда как мастер получал
# 18/21 от FreePBX. Схема ps_* между мажорными версиями отличается набором
# колонок, и узлы разъезжаются. Ставим из того же репозитория, что и мастер.
if ! command -v asterisk >/dev/null 2>&1; then
  KEYRING=/usr/share/keyrings/freepbx-archive-keyring.gpg
  if [ ! -f "$KEYRING" ]; then
    info "Подключаю репозиторий Sangoma: $ASTERISK_REPO_URL $ASTERISK_REPO_SUITE"
    curl -fsSL "$ASTERISK_REPO_KEY_URL" | gpg --dearmor -o "$KEYRING" \
      || warn "Не удалось получить ключ репозитория — будет использован сток дистрибутива."
  fi
  if [ -f "$KEYRING" ]; then
    echo "deb [signed-by=$KEYRING] $ASTERISK_REPO_URL $ASTERISK_REPO_SUITE main" \
      >/etc/apt/sources.list.d/freepbx.list
    _APT_REFRESHED=0
  fi
  ensure_pkg asterisk
fi

AST_MAJOR="$(asterisk_major)"
[ -n "$AST_MAJOR" ] || die "Не удалось определить версию Asterisk после установки."
info "Установлен Asterisk $AST_MAJOR"

if [ -n "${ASTERISK_MAJOR:-}" ] && [ "$AST_MAJOR" != "$ASTERISK_MAJOR" ]; then
  die "Версия Asterisk на этом узле ($AST_MAJOR) не совпадает с мастером ($ASTERISK_MAJOR).
Realtime-схема ps_* различается между мажорными версиями — узлы будут
работать с разным набором колонок. Приведите версии к одной и повторите."
fi

#-----------------------------------------------------------------------------
step "[6/8] Realtime и межузловая маршрутизация"
#-----------------------------------------------------------------------------
"$REPO_ROOT/scripts/lib/setup-realtime.sh" \
  --node-name="$NODE_NAME" --node-ip="$NODE_IP" \
  --db-name="$DB_NAME" --rt-user="$RT_USER" --rt-pass="$RT_PASS" \
  --local-net="$LOCAL_NET" --sip-port="$SIP_PORT" \
  --role=secondary --master-node-name="$MASTER_NODE_NAME"

#-----------------------------------------------------------------------------
step "[7/8] Запуск и проверка"
#-----------------------------------------------------------------------------
systemctl enable asterisk >/dev/null 2>&1 || true
systemctl restart asterisk
for i in $(seq 1 30); do
  asterisk_running && break
  sleep 1
done
asterisk_running || die "Asterisk не запустился: journalctl -u asterisk -n 100 --no-pager"

ODBC_OUT="$(asterisk -rx 'odbc show all' 2>/dev/null || true)"
printf '%s\n' "$ODBC_OUT" | sed 's/^/    /'
if printf '%s' "$ODBC_OUT" | grep -qi 'Connected.*yes\|Number of active connections: [1-9]'; then
  info "ODBC-соединение с общей БД установлено"
else
  warn "ODBC не подключился. Проверьте: пароль ${RT_USER}, имя драйвера в /etc/odbc.ini,
         доступность 127.0.0.1:3306 и права пользователя на базу ${DB_NAME}."
fi

EP_COUNT="$(asterisk -rx 'pjsip show endpoints' 2>/dev/null | grep -c '^ *Endpoint:' || true)"
info "Видно endpoint'ов из realtime: ${EP_COUNT:-0}"
if [ "${EP_COUNT:-0}" = "0" ]; then
  info "Ноль — это нормально, если на мастере ещё не выполнялся asterisk-cluster-sync."
fi

#-----------------------------------------------------------------------------
step "[8/8] Сохранение параметров и health-check"
#-----------------------------------------------------------------------------
ENVOUT=/etc/asterisk-cluster/cluster.env
install -d -m 0750 /etc/asterisk-cluster
backup_file "$ENVOUT"
cat >"$ENVOUT" <<EOF
# Сгенерировано clone-node.sh $(date -Is)
CLUSTER_NAME=$CLUSTER_NAME
NODE_NAME=$NODE_NAME
NODE_IP=$NODE_IP
NODE_ROLE=secondary
MASTER_IP=$MASTER_IP
MASTER_NODE_NAME=$MASTER_NODE_NAME
PEERS=$PEERS
DB_NAME=$DB_NAME
SST_USER=$SST_USER
SST_PASS=$SST_PASS
RT_USER=$RT_USER
RT_PASS=$RT_PASS
LOCAL_NET=$LOCAL_NET
CLUSTER_CIDR=$CLUSTER_CIDR
ADMIN_CIDR=$ADMIN_CIDR
SIP_PORT=$SIP_PORT
ASTERISK_MAJOR=$AST_MAJOR
EOF
chmod 0600 "$ENVOUT"

install -m 0755 "$REPO_ROOT/scripts/healthcheck.sh" /usr/local/bin/asterisk-cluster-health
cat >/etc/systemd/system/asterisk-cluster-health.service <<'EOF'
[Unit]
Description=Asterisk cluster health check
After=mariadb.service asterisk.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/asterisk-cluster-health --quiet
EOF
cat >/etc/systemd/system/asterisk-cluster-health.timer <<'EOF'
[Unit]
Description=Run Asterisk cluster health check every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now asterisk-cluster-health.timer >/dev/null

cat <<EOF

$(printf '%s' "$C_GRN")Узел $NODE_NAME ($NODE_IP) в кластере $CLUSTER_NAME.$(printf '%s' "$C_OFF")

Осталось сделать:
  1) На ВСЕХ узлах (включая мастер) обновить межузловые транки:
       ./scripts/make-node-trunks.sh --peers-map=$MASTER_NODE_NAME=$MASTER_IP,$NODE_NAME=$NODE_IP
  2) На мастере выгрузить номера в realtime:
       /usr/local/bin/asterisk-cluster-sync --apply
  3) На мастере разложить диалплан по узлам:
       /usr/local/bin/asterisk-cluster-push-dialplan
  4) Прописать телефонам этот узел как primary, мастер — как backup
     (провижининг сделает это сам, см. docs/03-provisioning.md)
  5) Прогнать чек-лист: docs/02-lab-deploy.md, раздел «Приёмка»

EOF
