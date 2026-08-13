#!/bin/bash
#
# prepare-clone.sh — превращает КЛОН виртуальной машины мастера в
# самостоятельный узел кластера.
#
# Зачем клонировать, а не ставить с нуля:
#   - версия Asterisk и набор модулей гарантированно совпадают с мастером,
#     а расхождение мажорных версий ломает realtime-схему ps_*;
#   - на клоне уже есть копия базы, поэтому вступление в кластер идёт
#     через IST (дослать пропущенное), а не через полный SST;
#   - не нужно повторять установку FreePBX и настройку окружения.
#
# Чем клон опасен, если его не расшить:
#   - одинаковый systemname на двух узлах: записи в ps_contacts.reg_server
#     станут неразличимы, и вызовы поедут не туда;
#   - унаследованное состояние Galera: узел попытается подняться как член
#     прежнего кластера со своей историей;
#   - второй работающий веб-интерфейс FreePBX, пишущий в ту же базу;
#   - одинаковые machine-id и ключи SSH на всех клонах.
#
# Запускать НА КЛОНЕ, сразу после первого включения и смены IP:
#
#   ./scripts/prepare-clone.sh \
#     --node-name=stavropol --node-ip=10.6.1.10 \
#     --master-ip=10.1.10.111 --master-node-name=rostov \
#     --peers=10.1.10.111,10.4.3.6,10.6.1.10 \
#     --sst-pass='...' --rt-pass='...'
#
#   ./scripts/prepare-clone.sh --role=standby …   # резервный мастер
#
# Роли:
#   secondary — узел площадки: GUI выключен, Asterisk обслуживает вызовы
#   standby   — резервный мастер: и GUI, и Asterisk выключены до промоушена
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

ROLE=secondary
ASSUME_YES=0
KEEP_DB=1

for arg in "$@"; do
  case $arg in
    --node-name=*)        NODE_NAME="${arg#*=}" ;;
    --node-ip=*)          NODE_IP="${arg#*=}" ;;
    --master-ip=*)        MASTER_IP="${arg#*=}" ;;
    --master-node-name=*) MASTER_NODE_NAME="${arg#*=}" ;;
    --peers=*)            PEERS="${arg#*=}" ;;
    --cluster-name=*)     CLUSTER_NAME="${arg#*=}" ;;
    --sst-pass=*)         SST_PASS="${arg#*=}" ;;
    --rt-pass=*)          RT_PASS="${arg#*=}" ;;
    --rt-user=*)          RT_USER="${arg#*=}" ;;
    --sst-user=*)         SST_USER="${arg#*=}" ;;
    --db-name=*)          DB_NAME="${arg#*=}" ;;
    --local-net=*)        LOCAL_NET="${arg#*=}" ;;
    --role=*)             ROLE="${arg#*=}" ;;
    --full-resync)        KEEP_DB=0 ;;
    --yes|-y)             ASSUME_YES=1 ;;
    -h|--help)            sed -n '2,40p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
case "$ROLE" in
  secondary|standby) ;;
  *) die "Недопустимая роль '$ROLE'. Допустимо: secondary, standby." ;;
esac

: "${NODE_NAME:?--node-name обязателен}"
: "${NODE_IP:?--node-ip обязателен}"
: "${MASTER_IP:?--master-ip обязателен}"
: "${PEERS:?--peers обязателен: полный список IP всех узлов}"
: "${SST_PASS:?--sst-pass обязателен}"
: "${RT_PASS:?--rt-pass обязателен}"
: "${MASTER_NODE_NAME:=rostov}"
: "${CLUSTER_NAME:=asterisk_prod}"
: "${SST_USER:=sst_user}"
: "${RT_USER:=asterisk_rt}"
: "${DB_NAME:=asterisk}"
: "${LOCAL_NET:=10.0.0.0/8}"
: "${SIP_PORT:=5060}"

require_node_name "$NODE_NAME"
require_node_name "$MASTER_NODE_NAME"
require_ipv4 --node-ip "$NODE_IP"
require_ipv4 --master-ip "$MASTER_IP"
case ",$PEERS," in
  *",$NODE_IP,"*) ;;
  *) die "NODE_IP $NODE_IP отсутствует в --peers ($PEERS)." ;;
esac

#-----------------------------------------------------------------------------
step "[1/9] Проверка, что это действительно клон мастера"
#-----------------------------------------------------------------------------
command -v asterisk >/dev/null 2>&1 || die "Asterisk не найден — это не клон мастера."
command -v mysql    >/dev/null 2>&1 || die "MariaDB не найдена — это не клон мастера."

AST_MAJOR="$(asterisk_major)"
[ -n "$AST_MAJOR" ] || die "Не удалось определить версию Asterisk."
info "Asterisk $AST_MAJOR"

# IP клона обязан быть уже изменён: иначе два узла с одним адресом.
if ! ip -4 addr show | grep -qw "$NODE_IP"; then
  die "Адрес $NODE_IP не назначен ни одному интерфейсу.
Смените IP клона ДО запуска этого скрипта — иначе он и мастер будут спорить
за один адрес."
fi
if ip -4 addr show | grep -qw "$MASTER_IP"; then
  die "На этой машине всё ещё висит адрес мастера $MASTER_IP.
Похоже, IP клона не сменён. Это приведёт к конфликту адресов в сети."
fi

OLD_SYSNAME="$(sed -n 's/^\s*systemname\s*=\s*\(.*\)$/\1/p' /etc/asterisk/asterisk.conf 2>/dev/null | head -1 | tr -d ' ')"
info "systemname на клоне сейчас: ${OLD_SYSNAME:-(не задан)}"
if [ "$OLD_SYSNAME" = "$NODE_NAME" ]; then
  warn "systemname уже равен '$NODE_NAME' — похоже, скрипт уже отрабатывал."
fi

cat <<EOF

  Клон будет превращён в узел кластера:

    Новое имя узла:  $NODE_NAME
    Адрес:           $NODE_IP
    Роль:            $ROLE
    Мастер:          $MASTER_NODE_NAME ($MASTER_IP)
    Все узлы:        $PEERS

  Что будет сделано:
    - сменены hostname, machine-id и ключи SSH (унаследованы от мастера)
    - systemname сменён с '${OLD_SYSNAME:-?}' на '$NODE_NAME'
    - веб-интерфейс FreePBX отключён (второй GUI на общей базе недопустим)
    - очищены унаследованные регистрации, CDR и журналы
    - сброшено состояние Galera, узел вступит в кластер заново
    - настроен realtime и кластерная маршрутизация
$([ "$ROLE" = standby ] && echo "    - Asterisk остановлен и выключен из автозапуска (резерв)")

EOF
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Продолжить? [y/N] " a
  case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено." ;; esac
fi

#-----------------------------------------------------------------------------
step "[2/9] Идентичность машины"
#-----------------------------------------------------------------------------
# Всё это клон унаследовал от мастера. Одинаковый machine-id ломает
# журналирование и DHCP, одинаковые ключи SSH — доверие к хостам.
hostnamectl set-hostname "$NODE_NAME" 2>/dev/null || {
  echo "$NODE_NAME" >/etc/hostname
  hostname "$NODE_NAME" 2>/dev/null || true
}
if grep -qE '^\s*127\.0\.1\.1' /etc/hosts; then
  sed -i "s/^\s*127\.0\.1\.1.*/127.0.1.1\t$NODE_NAME/" /etc/hosts
else
  printf '127.0.1.1\t%s\n' "$NODE_NAME" >>/etc/hosts
fi
info "hostname: $NODE_NAME"

if [ -f /etc/machine-id ]; then
  : >/etc/machine-id
  rm -f /var/lib/dbus/machine-id
  systemd-machine-id-setup >/dev/null 2>&1 || true
  ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true
  info "machine-id перегенерирован"
fi

if ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1; then
  rm -f /etc/ssh/ssh_host_*
  dpkg-reconfigure -f noninteractive openssh-server >/dev/null 2>&1 \
    || ssh-keygen -A >/dev/null 2>&1 || true
  systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
  info "Ключи хоста SSH перевыпущены"
fi

#-----------------------------------------------------------------------------
step "[3/9] Отключение веб-интерфейса FreePBX"
#-----------------------------------------------------------------------------
# Два GUI, пишущих в одну общую базу, — это гонка правок и рассинхрон
# сгенерированных конфигов. Управление остаётся только на мастере.
for svc in apache2 httpd nginx; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\."; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" >/dev/null 2>&1 || true
    info "$svc остановлен и убран из автозапуска"
  fi
done
# Планировщик FreePBX на клоне тоже лишний: он будет пересобирать конфиги
# и слать уведомления от имени второго «мастера».
if systemctl list-unit-files 2>/dev/null | grep -q '^freepbx\.'; then
  systemctl stop freepbx 2>/dev/null || true
  systemctl disable freepbx >/dev/null 2>&1 || true
  info "служба freepbx отключена"
fi
crontab -l 2>/dev/null | grep -q fwconsole && {
  crontab -l 2>/dev/null | grep -v fwconsole | crontab - || true
  info "задания cron от fwconsole убраны"
}

#-----------------------------------------------------------------------------
step "[4/9] Очистка унаследованных данных"
#-----------------------------------------------------------------------------
systemctl stop asterisk 2>/dev/null || true

# Регистрации, унаследованные от мастера, указывают на его systemname.
# Оставленные, они заставят кластер думать, что абоненты живут здесь.
if [ -f /var/lib/asterisk/astdb.sqlite3 ]; then
  backup_file /var/lib/asterisk/astdb.sqlite3
  rm -f /var/lib/asterisk/astdb.sqlite3
  info "Локальная astdb очищена"
fi

rm -f /var/log/asterisk/full* /var/log/asterisk/messages* \
      /var/log/asterisk/security* /var/log/asterisk/queue_log* 2>/dev/null || true
rm -rf /var/spool/asterisk/monitor/* /var/spool/asterisk/voicemail/default/* 2>/dev/null || true
info "Журналы, записи разговоров и голосовая почта мастера удалены"

#-----------------------------------------------------------------------------
step "[5/9] Сброс состояния Galera"
#-----------------------------------------------------------------------------
systemctl stop mariadb 2>/dev/null || true

# grastate.dat и gvwstate.dat описывают членство в ПРЕЖНЕМ кластере.
# С ними узел попробует восстановить старое представление о составе.
for f in /var/lib/mysql/grastate.dat /var/lib/mysql/gvwstate.dat; do
  [ -f "$f" ] && { backup_file "$f"; rm -f "$f"; info "удалён $(basename "$f")"; }
done

if [ "$KEEP_DB" = 0 ]; then
  warn "--full-resync: содержимое /var/lib/mysql будет удалено, узел получит полный SST."
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Точно удалить локальную копию базы? [y/N] " a
    case "$a" in y|Y|yes|да|Да) ;; *) die "Отменено." ;; esac
  fi
  find /var/lib/mysql -mindepth 1 -maxdepth 1 \
       ! -name 'mysql' ! -name 'performance_schema' -exec rm -rf {} + 2>/dev/null || true
  info "Локальная копия базы удалена — при старте пойдёт SST"
else
  info "Копия базы сохранена: если история донора это позволит, вступление"
  info "пройдёт через IST и займёт минуты вместо полного переноса"
fi

#-----------------------------------------------------------------------------
step "[6/9] Конфигурация Galera"
#-----------------------------------------------------------------------------
WSREP_SLAVE_THREADS="$(nproc)"; [ "$WSREP_SLAVE_THREADS" -gt 8 ] && WSREP_SLAVE_THREADS=8
GCACHE_SIZE="1G"
export NODE_NAME NODE_IP PEERS CLUSTER_NAME SST_USER SST_PASS \
       WSREP_SLAVE_THREADS GCACHE_SIZE

CNF_DIR=/etc/mysql/mariadb.conf.d
[ -d "$CNF_DIR" ] || CNF_DIR=/etc/mysql/conf.d
[ -d "$CNF_DIR" ] || die "Не найден каталог конфигурации MariaDB."
render_tpl "$REPO_ROOT/config/galera/60-galera.cnf.tpl" "$CNF_DIR/60-galera.cnf" 0640

step "    Вступление в кластер"
systemctl start mariadb &
START_PID=$!
SYNCED=0
for i in $(seq 1 300); do
  if mysqladmin ping >/dev/null 2>&1; then
    ST="$(wsrep_status wsrep_local_state_comment)"
    [ "$ST" = "Synced" ] && { SYNCED=1; break; }
    [ $((i % 15)) -eq 0 ] && info "  ... $ST (${i}s)"
  else
    [ $((i % 30)) -eq 0 ] && info "  ... MariaDB поднимается (${i}s)"
  fi
  sleep 1
done
wait "$START_PID" 2>/dev/null || true

SIZE="$(cluster_size)"
if [ "$SYNCED" != 1 ]; then
  warn "Узел не достиг Synced за 300 с (состояние: $(wsrep_status wsrep_local_state_comment))."
  warn "Проверьте: journalctl -u mariadb -n 200 --no-pager"
  warn "Частая причина после клонирования — расхождение UUID кластера."
  warn "Тогда повторите с --full-resync: узел получит полную копию заново."
  die "Прерываю."
fi
info "Синхронизирован. Размер кластера: $SIZE"

#-----------------------------------------------------------------------------
step "[7/9] Realtime и кластерная маршрутизация"
#-----------------------------------------------------------------------------
"$REPO_ROOT/scripts/lib/setup-realtime.sh" \
  --node-name="$NODE_NAME" --node-ip="$NODE_IP" \
  --db-name="$DB_NAME" --rt-user="$RT_USER" --rt-pass="$RT_PASS" \
  --local-net="$LOCAL_NET" --sip-port="$SIP_PORT" \
  --role=secondary --master-node-name="$MASTER_NODE_NAME"

#-----------------------------------------------------------------------------
step "[8/9] Запуск"
#-----------------------------------------------------------------------------
if [ "$ROLE" = "standby" ]; then
  systemctl stop asterisk 2>/dev/null || true
  systemctl disable asterisk >/dev/null 2>&1 || true
  install -d -m 0750 /etc/asterisk-cluster
  cat >/etc/asterisk-cluster/standby-master <<EOF
# Резервный мастер, подготовлен клонированием: prepare-clone.sh --role=standby
STANDBY_FOR=$MASTER_NODE_NAME
STANDBY_FOR_IP=$MASTER_IP
PREPARED_AT=$(date -Is)
EOF
  chmod 0640 /etc/asterisk-cluster/standby-master
  info "Asterisk остановлен: узел ждёт в резерве"
  info "Управление резервом: scripts/setup-standby-master.sh --status | --promote"
else
  systemctl enable asterisk >/dev/null 2>&1 || true
  systemctl restart asterisk
  for i in $(seq 1 30); do asterisk_running && break; sleep 1; done
  asterisk_running || die "Asterisk не запустился: journalctl -u asterisk -n 100"
  asterisk -rx 'odbc show all' 2>/dev/null | sed 's/^/    /' | head -6
  EP="$(asterisk -rx 'pjsip show endpoints' 2>/dev/null | grep -c '^ *Endpoint:' || echo 0)"
  info "Видно endpoint'ов из общей базы: $EP"
fi

#-----------------------------------------------------------------------------
step "[9/9] Параметры узла"
#-----------------------------------------------------------------------------
ENVOUT=/etc/asterisk-cluster/cluster.env
install -d -m 0750 /etc/asterisk-cluster
backup_file "$ENVOUT"
cat >"$ENVOUT" <<EOF
# Сгенерировано prepare-clone.sh $(date -Is)
CLUSTER_NAME=$CLUSTER_NAME
NODE_NAME=$NODE_NAME
NODE_IP=$NODE_IP
NODE_ROLE=$ROLE
MASTER_IP=$MASTER_IP
MASTER_NODE_NAME=$MASTER_NODE_NAME
PEERS=$PEERS
DB_NAME=$DB_NAME
SST_USER=$SST_USER
SST_PASS=$SST_PASS
RT_USER=$RT_USER
RT_PASS=$RT_PASS
LOCAL_NET=$LOCAL_NET
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

$(printf '%s' "$C_GRN")Клон превращён в узел $NODE_NAME ($NODE_IP), роль $ROLE.$(printf '%s' "$C_OFF")

Проверьте на мастере, что узел виден и имя не задвоилось:
  mysql -e "SELECT reg_server, COUNT(*) FROM asterisk.ps_contacts GROUP BY reg_server;"

Дальше:
  1) Межузловые транки на ВСЕХ узлах с обновлённой картой:
       ./scripts/make-node-trunks.sh --peers-map=…,$NODE_NAME=$NODE_IP
  2) Свой выход в город:
       ./scripts/setup-local-trunk.sh --trunk-name=… --host=… --user=… --pass=… --did=…
  3) Перевести телефоны площадки на этот узел:
       epm-set-site --sites sites.conf --apply --rebuild

EOF
