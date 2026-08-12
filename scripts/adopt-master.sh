#!/bin/bash
#
# adopt-master.sh — превращает УЖЕ РАБОТАЮЩУЮ АТС FreePBX в мастер кластера.
#
# В отличие от install-master.sh здесь ничего не устанавливается заново:
# FreePBX, Asterisk, номера, диалплан, транки и OSS Endpoint Manager
# остаются как есть. Добавляется только то, чего не хватает для кластера:
#
#   - MariaDB переводится в режим Galera поверх существующей базы;
#   - схема приводится к InnoDB (Galera не реплицирует MyISAM);
#   - ps_contacts выносится в realtime, чтобы площадки видели регистрации;
#   - задаётся systemname — по нему кластер узнаёт, где живёт абонент;
#   - подключается кластерная маршрутизация в extensions_custom.conf.
#
# Запускать НА СУЩЕСТВУЮЩЕЙ АТС от root:
#
#   ./scripts/adopt-master.sh \
#     --node-name=rostov --node-ip=10.1.10.111 \
#     --peers=10.1.10.111,10.4.3.6 --cluster-name=asterisk_prod
#
# ВАЖНО: MariaDB будет перезапущена. Это перерыв в обслуживании порядка
# минуты: активные разговоры не рвутся (медиа идёт напрямую), но новые
# вызовы в это время не устанавливаются. Планируйте окно.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env

ASSUME_YES=0
SKIP_BACKUP=0
BACKUP_DIR=/var/backups/asterisk-cluster

for arg in "$@"; do
  case $arg in
    --node-name=*)    NODE_NAME="${arg#*=}" ;;
    --node-ip=*)      NODE_IP="${arg#*=}" ;;
    --peers=*)        PEERS="${arg#*=}" ;;
    --cluster-name=*) CLUSTER_NAME="${arg#*=}" ;;
    --db-name=*)      DB_NAME="${arg#*=}" ;;
    --cdr-db=*)       CDR_DB_NAME="${arg#*=}" ;;
    --cluster-cidr=*) CLUSTER_CIDR="${arg#*=}" ;;
    --local-net=*)    LOCAL_NET="${arg#*=}" ;;
    --backup-dir=*)   BACKUP_DIR="${arg#*=}" ;;
    --skip-backup)    SKIP_BACKUP=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root

: "${NODE_NAME:?--node-name обязателен}"
: "${NODE_IP:?--node-ip обязателен}"
: "${PEERS:?--peers обязателен: полный список IP всех будущих узлов}"
: "${CLUSTER_NAME:=asterisk_prod}"
: "${DB_NAME:=asterisk}"
: "${CDR_DB_NAME:=asteriskcdrdb}"
: "${LOCAL_NET:=10.0.0.0/8}"
: "${CLUSTER_CIDR:=$LOCAL_NET}"
: "${SIP_PORT:=5060}"
: "${SST_USER:=sst_user}"
: "${RT_USER:=asterisk_rt}"

require_node_name "$NODE_NAME"
require_ipv4 --node-ip "$NODE_IP"
case ",$PEERS," in
  *",$NODE_IP,"*) ;;
  *) die "NODE_IP $NODE_IP отсутствует в --peers ($PEERS)." ;;
esac

#-----------------------------------------------------------------------------
step "[1/9] Проверка существующей установки"
#-----------------------------------------------------------------------------
command -v asterisk  >/dev/null 2>&1 || die "Asterisk не найден. Это точно та машина?"
command -v fwconsole >/dev/null 2>&1 || warn "fwconsole не найден — FreePBX не обнаружен."
command -v mysql     >/dev/null 2>&1 || die "MariaDB/MySQL не найдены."

AST_MAJOR="$(asterisk_major)"
[ -n "$AST_MAJOR" ] || die "Не удалось определить версию Asterisk."
info "Asterisk $AST_MAJOR ($(asterisk -V 2>/dev/null))"
info "MariaDB: $(mysql -V | sed 's/.*Distrib \([^,]*\).*/\1/')"
if command -v fwconsole >/dev/null 2>&1; then
  info "FreePBX: $(fwconsole --version 2>/dev/null | head -1)"
fi

wait_for_mysql 15 || die "MariaDB не отвечает."

EXT_COUNT="$(mysql_local -e "SELECT COUNT(*) FROM \`$DB_NAME\`.users;" 2>/dev/null || echo '?')"
DEV_COUNT="$(mysql_local -e "SELECT COUNT(*) FROM \`$DB_NAME\`.devices;" 2>/dev/null || echo '?')"
EPM_COUNT="$(mysql_local -e "SELECT COUNT(*) FROM \`$DB_NAME\`.endpointman_mac_list;" 2>/dev/null || echo '0')"
info "Добавочных: ${EXT_COUNT}, устройств: ${DEV_COUNT}, телефонов в EPM: ${EPM_COUNT}"

if mysql_local -e "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | grep -q wsrep; then
  CUR_SIZE="$(cluster_size)"
  if [ "$CUR_SIZE" -ge 1 ]; then
    warn "MariaDB уже работает в режиме Galera (размер кластера: $CUR_SIZE)."
    warn "Повторный прогон обновит конфигурацию, но bootstrap выполняться не будет."
  fi
fi

cat <<EOF

  Существующая АТС станет мастером кластера:

    Узел:      $NODE_NAME ($NODE_IP)
    Кластер:   $CLUSTER_NAME
    Все узлы:  $PEERS
    База:      $DB_NAME (CDR: $CDR_DB_NAME)

  Что изменится:
    - MariaDB перейдёт в режим Galera и будет ПЕРЕЗАПУЩЕНА
    - таблицы MyISAM будут сконвертированы в InnoDB
    - появятся пользователи БД $SST_USER и $RT_USER
    - ps_contacts станет realtime-таблицей (общей для кластера)
    - в asterisk.conf будет задан systemname = $NODE_NAME
    - в extensions_custom.conf добавятся include кластерных контекстов

  Что НЕ изменится:
    - FreePBX, его модули и настройки, включая OSS Endpoint Manager
    - добавочные, диалплан, IVR, очереди, транки
    - конфигурация телефонов

EOF
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Продолжить? [y/N] " a
  case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено." ;; esac
fi

#-----------------------------------------------------------------------------
step "[2/9] Резервная копия"
#-----------------------------------------------------------------------------
if [ "$SKIP_BACKUP" = 1 ]; then
  warn "Пропущено по --skip-backup. Вы уверены, что копия уже есть?"
else
  install -d -m 0700 "$BACKUP_DIR"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  info "Дамп баз в $BACKUP_DIR ..."
  mysqldump --single-transaction --routines --triggers --events \
            --databases "$DB_NAME" | gzip > "$BACKUP_DIR/db-${STAMP}.sql.gz"
  info "  $(du -h "$BACKUP_DIR/db-${STAMP}.sql.gz" | cut -f1) — $DB_NAME"

  info "Копия /etc/asterisk ..."
  tar czf "$BACKUP_DIR/etc-asterisk-${STAMP}.tar.gz" -C /etc asterisk 2>/dev/null || true

  if command -v fwconsole >/dev/null 2>&1; then
    info "Бэкап FreePBX (fwconsole)..."
    fwconsole backup --backup=1 >/dev/null 2>&1 \
      || warn "  fwconsole backup не отработал — дамп БД и конфиги уже сняты."
  fi
  log "Резервная копия готова: $BACKUP_DIR (stamp $STAMP)"
fi

#-----------------------------------------------------------------------------
step "[3/9] Аудит схемы под Galera"
#-----------------------------------------------------------------------------
NON_INNODB="$(mysql_local -e "
  SELECT CONCAT(table_schema,'.',table_name)
  FROM information_schema.tables
  WHERE table_schema = '$DB_NAME'
    AND engine IS NOT NULL AND engine <> 'InnoDB';" || true)"

if [ -n "$NON_INNODB" ]; then
  COUNT="$(printf '%s\n' "$NON_INNODB" | grep -c .)"
  info "Таблиц не в InnoDB: $COUNT — конвертирую"
  printf '%s\n' "$NON_INNODB" | head -10 | sed 's/^/      /'
  [ "$COUNT" -gt 10 ] && info "      ... и ещё $((COUNT - 10))"
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    mysql_exec "ALTER TABLE ${t} ENGINE=InnoDB;" 2>/dev/null \
      || warn "не удалось сконвертировать $t"
  done <<<"$NON_INNODB"
  log "Конвертация завершена"
else
  info "Все таблицы уже InnoDB"
fi

NO_PK="$(mysql_local -e "
  SELECT CONCAT(t.table_schema,'.',t.table_name)
  FROM information_schema.tables t
  LEFT JOIN information_schema.table_constraints c
    ON c.table_schema = t.table_schema AND c.table_name = t.table_name
   AND c.constraint_type = 'PRIMARY KEY'
  WHERE t.table_schema = '$DB_NAME'
    AND t.table_type = 'BASE TABLE' AND c.constraint_name IS NULL;" || true)"
if [ -n "$NO_PK" ]; then
  warn "Таблицы без первичного ключа (Galera реплицирует их неэффективно):"
  printf '%s\n' "$NO_PK" | sed 's/^/      /'
fi

# CDR оставляем локальной: она пишется на каждый звонок и не имеет
# первичного ключа — синхронно реплицировать её на все площадки незачем.
info "База $CDR_DB_NAME в кластер НЕ включается (см. docs/05-operations.md)"

#-----------------------------------------------------------------------------
step "[4/9] Пакеты Galera"
#-----------------------------------------------------------------------------
ensure_pkg galera-4 mariadb-backup rsync socat python3 python3-pymysql

#-----------------------------------------------------------------------------
step "[5/9] Пользователи БД"
#-----------------------------------------------------------------------------
: "${SST_PASS:=$(gen_secret 32)}"
: "${RT_PASS:=$(gen_secret 32)}"

mysql_exec "CREATE USER IF NOT EXISTS '${SST_USER}'@'localhost' IDENTIFIED BY '${SST_PASS}';"
mysql_exec "ALTER USER '${SST_USER}'@'localhost' IDENTIFIED BY '${SST_PASS}';"
mysql_exec "GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO '${SST_USER}'@'localhost';" \
  || mysql_exec "GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${SST_USER}'@'localhost';"

for host in localhost '%'; do
  mysql_exec "CREATE USER IF NOT EXISTS '${RT_USER}'@'${host}' IDENTIFIED BY '${RT_PASS}';"
  mysql_exec "ALTER USER '${RT_USER}'@'${host}' IDENTIFIED BY '${RT_PASS}';"
  mysql_exec "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${DB_NAME}\`.* TO '${RT_USER}'@'${host}';"
done
mysql_exec "FLUSH PRIVILEGES;"
info "Созданы ${SST_USER} и ${RT_USER}"

#-----------------------------------------------------------------------------
step "[6/9] Firewall"
#-----------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  # Правила добавляются, но ufw НЕ включается: на работающей АТС включение
  # firewall'а может отрезать телефоны, транки или администратора.
  for port in 3306 4444 4567 4568; do
    ufw allow from "$CLUSTER_CIDR" to any port "$port" proto tcp comment 'galera' >/dev/null 2>&1 || true
  done
  if ufw status 2>/dev/null | grep -q 'Status: active'; then
    info "Правила Galera добавлены в активный ufw"
  else
    info "Правила Galera записаны; ufw не активен — включать не стал"
  fi
else
  warn "ufw не установлен. Откройте между узлами 3306, 4444, 4567, 4568/tcp вручную."
fi

#-----------------------------------------------------------------------------
step "[7/9] Перевод MariaDB в режим Galera"
#-----------------------------------------------------------------------------
WSREP_SLAVE_THREADS="$(nproc)"; [ "$WSREP_SLAVE_THREADS" -gt 8 ] && WSREP_SLAVE_THREADS=8
GCACHE_SIZE="2G"
export NODE_NAME NODE_IP PEERS CLUSTER_NAME SST_USER SST_PASS \
       WSREP_SLAVE_THREADS GCACHE_SIZE

CNF_DIR=/etc/mysql/mariadb.conf.d
[ -d "$CNF_DIR" ] || CNF_DIR=/etc/mysql/conf.d
[ -d "$CNF_DIR" ] || die "Не найден каталог конфигурации MariaDB."
render_tpl "$REPO_ROOT/config/galera/60-galera.cnf.tpl" "$CNF_DIR/60-galera.cnf" 0640

ALREADY_CLUSTER=0
[ "$(cluster_size)" -ge 1 ] && ALREADY_CLUSTER=1

if [ "$ALREADY_CLUSTER" = 1 ]; then
  info "Узел уже в кластере — перезапуск не требуется, применяю конфигурацию"
  systemctl reload mariadb 2>/dev/null || true
else
  warn "Перезапуск MariaDB. Новые вызовы не будут устанавливаться ~минуту."
  if [ "$ASSUME_YES" != 1 ]; then
    read -r -p "Перезапустить сейчас? [y/N] " a
    case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено. Конфигурация записана, примените позже." ;; esac
  fi
  systemctl stop mariadb
  galera_new_cluster || die "galera_new_cluster не отработал: journalctl -u mariadb -n 100"
  wait_for_mysql 120 || die "MariaDB не поднялась после перехода в Galera."
fi

SIZE="$(cluster_size)"
STATE="$(wsrep_status wsrep_local_state_comment)"
info "wsrep_cluster_size=${SIZE}, состояние: ${STATE}"
[ "$SIZE" -ge 1 ] || die "Кластер не собрался."

# Данные на месте?
NEW_EXT="$(mysql_local -e "SELECT COUNT(*) FROM \`$DB_NAME\`.users;" 2>/dev/null || echo '?')"
if [ "$NEW_EXT" != "$EXT_COUNT" ]; then
  warn "Число добавочных изменилось: было $EXT_COUNT, стало $NEW_EXT — проверьте!"
else
  info "Данные на месте: добавочных $NEW_EXT"
fi

#-----------------------------------------------------------------------------
step "[8/9] Realtime и кластерная маршрутизация"
#-----------------------------------------------------------------------------
"$REPO_ROOT/scripts/lib/setup-realtime.sh" \
  --node-name="$NODE_NAME" --node-ip="$NODE_IP" \
  --db-name="$DB_NAME" --rt-user="$RT_USER" --rt-pass="$RT_PASS" \
  --local-net="$LOCAL_NET" --sip-port="$SIP_PORT" --role=master

# Схема ps_contacts должна существовать: на чистом FreePBX её создаёт
# alembic вместе с остальной realtime-схемой, но если её нет — создаём.
if ! mysql_local -e "SELECT 1 FROM \`$DB_NAME\`.ps_contacts LIMIT 1;" >/dev/null 2>&1; then
  warn "Таблицы ps_contacts нет — создаю по схеме Asterisk ${AST_MAJOR}."
  mysql --protocol=socket "$DB_NAME" < "$REPO_ROOT/sql/03-ps-contacts.sql" \
    && info "ps_contacts создана" \
    || die "Не удалось создать ps_contacts. Обычно её создаёт alembic из contrib/ast-db-manage."
fi

info "Перезапускаю Asterisk для применения systemname..."
systemctl restart asterisk
for i in $(seq 1 30); do asterisk_running && break; sleep 1; done
asterisk_running || die "Asterisk не поднялся: journalctl -u asterisk -n 100"

asterisk -rx 'odbc show all' 2>/dev/null | sed 's/^/    /' | head -8
REG="$(mysql_local -e "SELECT COUNT(*) FROM \`$DB_NAME\`.ps_contacts;" 2>/dev/null || echo 0)"
info "Регистраций в общей таблице ps_contacts: $REG"
if [ "$REG" = "0" ]; then
  info "Ноль сразу после перезапуска — норма: телефоны перерегистрируются в течение таймера."
fi

#-----------------------------------------------------------------------------
step "[9/9] Параметры и служебные команды"
#-----------------------------------------------------------------------------
ENVOUT=/etc/asterisk-cluster/cluster.env
install -d -m 0750 /etc/asterisk-cluster
backup_file "$ENVOUT"
cat >"$ENVOUT" <<EOF
# Сгенерировано adopt-master.sh $(date -Is)
CLUSTER_NAME=$CLUSTER_NAME
NODE_NAME=$NODE_NAME
NODE_IP=$NODE_IP
NODE_ROLE=master
PEERS=$PEERS
DB_NAME=$DB_NAME
CDR_DB_NAME=$CDR_DB_NAME
SST_USER=$SST_USER
SST_PASS=$SST_PASS
RT_USER=$RT_USER
RT_PASS=$RT_PASS
LOCAL_NET=$LOCAL_NET
CLUSTER_CIDR=$CLUSTER_CIDR
SIP_PORT=$SIP_PORT
ASTERISK_MAJOR=$AST_MAJOR
EOF
chmod 0600 "$ENVOUT"

install -m 0755 "$REPO_ROOT/scripts/healthcheck.sh"   /usr/local/bin/asterisk-cluster-health
install -m 0755 "$REPO_ROOT/scripts/sync-config.py"   /usr/local/bin/asterisk-cluster-sync
install -m 0755 "$REPO_ROOT/scripts/push-dialplan.sh" /usr/local/bin/asterisk-cluster-push-dialplan
install -m 0755 "$REPO_ROOT/scripts/epm-set-site.py"  /usr/local/bin/epm-set-site

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

$(printf '%s' "$C_GRN")АТС $NODE_NAME стала мастером кластера $CLUSTER_NAME.$(printf '%s' "$C_OFF")

Пароли (сохраните, они понадобятся при подключении площадок):
  SST  ${SST_USER} : ${SST_PASS}
  RT   ${RT_USER}  : ${RT_PASS}

Дальше:
  1) Выгрузить номера в realtime, чтобы их увидели площадки:
       asterisk-cluster-sync            # сначала посмотреть план
       asterisk-cluster-sync --apply
  2) Развернуть площадку:
       ./scripts/clone-node.sh --node-name=<имя> --node-ip=<ip> \\
         --master-ip=$NODE_IP --master-node-name=$NODE_NAME \\
         --peers=$PEERS --cluster-name=$CLUSTER_NAME \\
         --asterisk-major=$AST_MAJOR --sst-pass='<SST выше>' --rt-pass='<RT выше>'
  3) Межузловые транки на ВСЕХ узлах:
       ./scripts/make-node-trunks.sh --peers-map=$NODE_NAME=$NODE_IP,<имя>=<ip>
  4) Привязать телефоны EPM к площадкам (failover):
       см. docs/09-epm-integration.md, затем
       epm-set-site --sites sites.conf --apply --rebuild

EOF
