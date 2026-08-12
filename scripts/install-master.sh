#!/bin/bash
#
# install-master.sh — мастер-узел кластера: FreePBX (GUI, источник правды по
# номерам и диалплану) + MariaDB Galera (bootstrap) + realtime + провижининг.
#
# ПОРЯДОК ВАЖЕН И ОТЛИЧАЕТСЯ ОТ ЧЕРНОВИКА: сначала ставится FreePBX со своей
# MariaDB, и только потом БД переводится в режим Galera. В черновике было
# наоборот — инсталлятор FreePBX переписывал конфигурацию уже собранного
# кластера и ронял его.
#
# Запускать НА МАСТЕРЕ от root:
#
#   ./scripts/install-master.sh \
#     --node-name=rostov --node-ip=10.10.10.11 \
#     --peers=10.10.10.11,10.10.10.12 --cluster-name=asterisk_prod
#
# Параметры (или config/cluster.env):
#   --node-name=      имя узла: a-z0-9-
#   --node-ip=        IP этого узла в межузловой сети
#   --peers=          ВСЕ узлы кластера через запятую, включая этот
#   --cluster-name=   имя Galera-кластера
#   --skip-freepbx    не ставить FreePBX (он уже установлен)
#   --skip-provisioning  не разворачивать сервер автопровижининга
#   --admin-cidr=     откуда разрешён SSH и веб-интерфейс FreePBX
#   --yes             не задавать вопросов
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env

SKIP_FREEPBX=0
SKIP_PROV=0
ASSUME_YES=0
NODE_ROLE=master

for arg in "$@"; do
  case $arg in
    --node-name=*)    NODE_NAME="${arg#*=}" ;;
    --node-ip=*)      NODE_IP="${arg#*=}" ;;
    --peers=*)        PEERS="${arg#*=}" ;;
    --cluster-name=*) CLUSTER_NAME="${arg#*=}" ;;
    --admin-cidr=*)   ADMIN_CIDR="${arg#*=}" ;;
    --db-name=*)      DB_NAME="${arg#*=}" ;;
    --skip-freepbx)   SKIP_FREEPBX=1 ;;
    --skip-provisioning) SKIP_PROV=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    -h|--help)        sed -n '2,28p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
require_os_codename bookworm bullseye

: "${NODE_NAME:?--node-name обязателен}"
: "${NODE_IP:?--node-ip обязателен}"
: "${PEERS:?--peers обязателен (полный список узлов через запятую)}"
: "${CLUSTER_NAME:=asterisk_prod}"
: "${DB_NAME:=asterisk}"
: "${CDR_DB_NAME:=asteriskcdrdb}"
: "${ADMIN_CIDR:=10.0.0.0/8}"
: "${LOCAL_NET:=10.0.0.0/8}"
: "${CLUSTER_CIDR:=$LOCAL_NET}"
: "${PHONE_CIDR:=$LOCAL_NET}"
: "${SIP_PORT:=5060}"
: "${SIP_TLS_PORT:=5061}"
: "${RTP_START:=10000}"
: "${RTP_END:=20000}"
: "${SST_USER:=sst_user}"
: "${RT_USER:=asterisk_rt}"
: "${PROV_DB_USER:=prov_ro}"
: "${PROV_PORT:=8443}"

require_node_name "$NODE_NAME"
require_ipv4 --node-ip "$NODE_IP"

# Мастер обязан быть в списке peers, иначе после рестарта он не найдёт кластер.
case ",$PEERS," in
  *",$NODE_IP,"*) ;;
  *) die "NODE_IP $NODE_IP отсутствует в --peers ($PEERS). Список должен включать все узлы, в том числе этот." ;;
esac

# Секреты: генерируем, если не заданы. Рабочих значений по умолчанию нет
# сознательно — в черновике ChangeMe_* уезжали в прод как есть.
: "${SST_PASS:=$(gen_secret 32)}"
: "${RT_PASS:=$(gen_secret 32)}"
: "${PROV_DB_PASS:=$(gen_secret 32)}"
: "${PROV_HMAC_SECRET:=$(gen_secret 48)}"

WSREP_SLAVE_THREADS="$(nproc)"
[ "$WSREP_SLAVE_THREADS" -gt 8 ] && WSREP_SLAVE_THREADS=8
GCACHE_SIZE="1G"
export NODE_NAME NODE_IP PEERS CLUSTER_NAME DB_NAME SST_USER SST_PASS \
       RT_USER RT_PASS LOCAL_NET SIP_PORT WSREP_SLAVE_THREADS GCACHE_SIZE

cat <<EOF

  Узел:        $NODE_NAME ($NODE_IP), роль master
  Кластер:     $CLUSTER_NAME
  Все узлы:    $PEERS
  База:        $DB_NAME
  FreePBX:     $([ "$SKIP_FREEPBX" = 1 ] && echo "пропустить" || echo "установить")
  Провижининг: $([ "$SKIP_PROV" = 1 ] && echo "пропустить" || echo "установить на :$PROV_PORT")

EOF
if [ "$ASSUME_YES" != 1 ]; then
  read -r -p "Продолжить? [y/N] " a
  case "$a" in y|Y|yes|Да|да) ;; *) die "Отменено." ;; esac
fi

#-----------------------------------------------------------------------------
step "[1/9] Базовая подготовка ОС"
#-----------------------------------------------------------------------------
ensure_pkg curl wget git sudo vim ufw chrony socat rsync ca-certificates \
           python3 python3-pymysql netcat-openbsd

systemctl enable --now chrony >/dev/null 2>&1 || true

# SSH открывается ПЕРВЫМ и до `ufw enable`. В черновике ufw включался без
# правила на 22/tcp — это отключало администратора от сервера прямо на
# этой строке установки.
step "[2/9] Firewall"
ufw allow from "$ADMIN_CIDR" to any port 22 proto tcp comment 'ssh admin' >/dev/null
ufw allow 22/tcp comment 'ssh fallback' >/dev/null
info "SSH разрешён (в т.ч. запасное правило для всех адресов — сузьте после установки)"

for port in 3306 4444 4567 4568; do
  ufw allow from "$CLUSTER_CIDR" to any port "$port" proto tcp comment 'galera' >/dev/null
done
ufw allow "$SIP_PORT"/udp comment 'sip' >/dev/null
ufw allow "$SIP_TLS_PORT"/tcp comment 'sip tls' >/dev/null
ufw allow "${RTP_START}:${RTP_END}"/udp comment 'rtp' >/dev/null
ufw allow from "$ADMIN_CIDR" to any port 80 proto tcp comment 'freepbx gui' >/dev/null
ufw allow from "$ADMIN_CIDR" to any port 443 proto tcp comment 'freepbx gui tls' >/dev/null
[ "$SKIP_PROV" = 1 ] || ufw allow from "$PHONE_CIDR" to any port "$PROV_PORT" proto tcp comment 'provisioning' >/dev/null
ufw --force enable >/dev/null
info "ufw активен"

#-----------------------------------------------------------------------------
step "[3/9] FreePBX + Asterisk"
#-----------------------------------------------------------------------------
if [ "$SKIP_FREEPBX" = 1 ]; then
  info "Пропущено по --skip-freepbx"
  command -v asterisk >/dev/null 2>&1 || die "Asterisk не установлен, а --skip-freepbx задан."
else
  if command -v fwconsole >/dev/null 2>&1; then
    info "FreePBX уже установлен ($(fwconsole --version 2>/dev/null | head -1)) — пропускаю"
  else
    info "Запускаю официальный инсталлятор Sangoma (FreePBX 17 + Asterisk 21)."
    info "Это надолго: скачивание и сборка занимают 20-40 минут."
    SRC=/usr/src/sng_freepbx_debian_install
    if [ -d "$SRC/.git" ]; then
      git -C "$SRC" pull --ff-only >/dev/null 2>&1 || true
    else
      git clone --depth=1 https://github.com/FreePBX/sng_freepbx_debian_install.git "$SRC"
    fi
    # Инсталлятор ставит фиксированную связку под свою целевую ОС; выбора
    # версий, обещанного в черновике, у него нет.
    bash "$SRC/sng_freepbx_debian_install.sh"
  fi
fi

AST_MAJOR="$(asterisk_major)"
[ -n "$AST_MAJOR" ] || die "Не удалось определить версию Asterisk."
info "Asterisk $AST_MAJOR — эту же версию обязаны получить все secondary-узлы."

#-----------------------------------------------------------------------------
step "[4/9] Перевод MariaDB в режим Galera"
#-----------------------------------------------------------------------------
ensure_pkg mariadb-server mariadb-client mariadb-backup galera-4

wait_for_mysql 30 || { systemctl start mariadb; wait_for_mysql 60 || die "MariaDB не поднимается."; }

# Схема FreePBX содержит MyISAM-таблицы. Galera их НЕ реплицирует — узлы
# молча разъедутся по данным. Конвертируем до включения репликации.
step "    Аудит схемы перед репликацией"
NON_INNODB="$(mysql_local -e "
  SELECT CONCAT(table_schema,'.',table_name)
  FROM information_schema.tables
  WHERE table_schema IN ('$DB_NAME','$CDR_DB_NAME')
    AND engine IS NOT NULL AND engine <> 'InnoDB';" || true)"

if [ -n "$NON_INNODB" ]; then
  info "Таблицы не в InnoDB (будут сконвертированы):"
  printf '%s\n' "$NON_INNODB" | sed 's/^/      /'
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    mysql_exec "ALTER TABLE ${t} ENGINE=InnoDB;" || warn "Не удалось сконвертировать $t"
  done <<<"$NON_INNODB"
else
  info "Все таблицы уже InnoDB"
fi

NO_PK="$(mysql_local -e "
  SELECT CONCAT(t.table_schema,'.',t.table_name)
  FROM information_schema.tables t
  LEFT JOIN information_schema.table_constraints c
    ON c.table_schema = t.table_schema AND c.table_name = t.table_name
   AND c.constraint_type = 'PRIMARY KEY'
  WHERE t.table_schema IN ('$DB_NAME','$CDR_DB_NAME')
    AND t.table_type = 'BASE TABLE' AND c.constraint_name IS NULL;" || true)"
if [ -n "$NO_PK" ]; then
  warn "Таблицы без первичного ключа — Galera реплицирует их неэффективно:"
  printf '%s\n' "$NO_PK" | sed 's/^/      /'
  warn "Для CDR это ожидаемо. Рекомендация — вынести $CDR_DB_NAME из репликации"
  warn "(см. docs/05-operations.md, раздел «CDR вне Galera»)."
fi

step "    Пользователи БД"
mysql_exec "CREATE USER IF NOT EXISTS '${SST_USER}'@'localhost' IDENTIFIED BY '${SST_PASS}';"
mysql_exec "ALTER USER '${SST_USER}'@'localhost' IDENTIFIED BY '${SST_PASS}';"
# Права mariabackup. BINLOG MONITOR — имя с MariaDB 10.5; REPLICATION CLIENT
# оставлен как совместимый вариант для более старых сборок.
mysql_exec "GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO '${SST_USER}'@'localhost';" \
  || mysql_exec "GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO '${SST_USER}'@'localhost';"

for host in localhost '%'; do
  mysql_exec "CREATE USER IF NOT EXISTS '${RT_USER}'@'${host}' IDENTIFIED BY '${RT_PASS}';"
  mysql_exec "ALTER USER '${RT_USER}'@'${host}' IDENTIFIED BY '${RT_PASS}';"
  mysql_exec "GRANT SELECT, INSERT, UPDATE, DELETE ON \`${DB_NAME}\`.* TO '${RT_USER}'@'${host}';"
done
mysql_exec "FLUSH PRIVILEGES;"
info "Созданы ${SST_USER} и ${RT_USER}"

step "    Конфигурация Galera и bootstrap"
render_tpl "$REPO_ROOT/config/galera/60-galera.cnf.tpl" \
           /etc/mysql/mariadb.conf.d/60-galera.cnf 0640

systemctl stop mariadb
# Первый узел кластера поднимается через bootstrap: он объявляет себя
# Primary Component, остальные потом присоединяются к нему.
if galera_new_cluster; then
  info "Кластер инициализирован (bootstrap)"
else
  die "galera_new_cluster не отработал. Смотрите: journalctl -u mariadb -n 100"
fi
wait_for_mysql 60 || die "MariaDB не поднялась после bootstrap."

SIZE="$(cluster_size)"
STATE="$(wsrep_status wsrep_local_state_comment)"
info "wsrep_cluster_size=${SIZE}, состояние: ${STATE}"
[ "$SIZE" -ge 1 ] || die "Кластер не собрался."

#-----------------------------------------------------------------------------
step "[5/9] Realtime: ODBC на мастере"
#-----------------------------------------------------------------------------
"$REPO_ROOT/scripts/lib/setup-realtime.sh" \
  --node-name="$NODE_NAME" --node-ip="$NODE_IP" \
  --db-name="$DB_NAME" --rt-user="$RT_USER" --rt-pass="$RT_PASS" \
  --local-net="$LOCAL_NET" --sip-port="$SIP_PORT" --role=master

#-----------------------------------------------------------------------------
step "[6/9] Схема провижининга и служебные таблицы"
#-----------------------------------------------------------------------------
mysql --protocol=socket "$DB_NAME" < "$REPO_ROOT/sql/01-provisioning-schema.sql"
info "Таблицы phone_provision / provision_log созданы"

mysql_exec "CREATE USER IF NOT EXISTS '${PROV_DB_USER}'@'localhost' IDENTIFIED BY '${PROV_DB_PASS}';"
mysql_exec "ALTER USER '${PROV_DB_USER}'@'localhost' IDENTIFIED BY '${PROV_DB_PASS}';"
# Отдельный пользователь строго на нужные таблицы: веб-скрипт не должен
# ходить под asterisk_rt, у которого есть запись во всю схему.
mysql_exec "GRANT SELECT ON \`${DB_NAME}\`.phone_provision TO '${PROV_DB_USER}'@'localhost';"
mysql_exec "GRANT SELECT ON \`${DB_NAME}\`.ps_auths TO '${PROV_DB_USER}'@'localhost';"
mysql_exec "GRANT SELECT ON \`${DB_NAME}\`.ps_endpoints TO '${PROV_DB_USER}'@'localhost';"
mysql_exec "GRANT SELECT, INSERT ON \`${DB_NAME}\`.provision_log TO '${PROV_DB_USER}'@'localhost';"
mysql_exec "GRANT UPDATE (provisioned_at, provision_count) ON \`${DB_NAME}\`.phone_provision TO '${PROV_DB_USER}'@'localhost';"
mysql_exec "FLUSH PRIVILEGES;"
info "Создан ${PROV_DB_USER} с доступом только на чтение нужных таблиц"

#-----------------------------------------------------------------------------
step "[7/9] Сервер автопровижининга"
#-----------------------------------------------------------------------------
if [ "$SKIP_PROV" = 1 ]; then
  info "Пропущено по --skip-provisioning"
else
  "$REPO_ROOT/scripts/install-provisioning.sh" \
    --db-name="$DB_NAME" --db-user="$PROV_DB_USER" --db-pass="$PROV_DB_PASS" \
    --hmac-secret="$PROV_HMAC_SECRET" --port="$PROV_PORT" \
    --phone-cidr="$PHONE_CIDR" --node-ip="$NODE_IP"
fi

#-----------------------------------------------------------------------------
step "[8/9] Сохранение параметров кластера"
#-----------------------------------------------------------------------------
ENVOUT=/etc/asterisk-cluster/cluster.env
install -d -m 0750 /etc/asterisk-cluster
backup_file "$ENVOUT"
cat >"$ENVOUT" <<EOF
# Сгенерировано install-master.sh $(date -Is)
# Файл содержит пароли: права 0600, в git не попадает.
CLUSTER_NAME=$CLUSTER_NAME
NODE_NAME=$NODE_NAME
NODE_IP=$NODE_IP
NODE_ROLE=$NODE_ROLE
PEERS=$PEERS
DB_NAME=$DB_NAME
CDR_DB_NAME=$CDR_DB_NAME
SST_USER=$SST_USER
SST_PASS=$SST_PASS
RT_USER=$RT_USER
RT_PASS=$RT_PASS
PROV_DB_USER=$PROV_DB_USER
PROV_DB_PASS=$PROV_DB_PASS
PROV_HMAC_SECRET=$PROV_HMAC_SECRET
PROV_PORT=$PROV_PORT
LOCAL_NET=$LOCAL_NET
ADMIN_CIDR=$ADMIN_CIDR
PHONE_CIDR=$PHONE_CIDR
CLUSTER_CIDR=$CLUSTER_CIDR
SIP_PORT=$SIP_PORT
ASTERISK_MAJOR=$AST_MAJOR
EOF
chmod 0600 "$ENVOUT"
info "Параметры сохранены в $ENVOUT"

#-----------------------------------------------------------------------------
step "[9/9] Health-check и таймер"
#-----------------------------------------------------------------------------
install -m 0755 "$REPO_ROOT/scripts/healthcheck.sh" /usr/local/bin/asterisk-cluster-health

# Выгрузка номеров FreePBX в realtime-таблицы и раскатка диалплана —
# основные операции сопровождения, кладём их в PATH.
install -m 0755 "$REPO_ROOT/scripts/sync-config.py"   /usr/local/bin/asterisk-cluster-sync
install -m 0755 "$REPO_ROOT/scripts/push-dialplan.sh" /usr/local/bin/asterisk-cluster-push-dialplan
info "Установлены asterisk-cluster-sync и asterisk-cluster-push-dialplan"

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
info "Таймер asterisk-cluster-health.timer включён"

cat <<EOF

$(printf '%s' "$C_GRN")Мастер $NODE_NAME готов.$(printf '%s' "$C_OFF")

Пароли (сохраните в менеджер секретов, потом сотрите вывод терминала):
  SST  ${SST_USER} : ${SST_PASS}
  RT   ${RT_USER}  : ${RT_PASS}
  PROV ${PROV_DB_USER} : ${PROV_DB_PASS}
  HMAC провижининга : ${PROV_HMAC_SECRET}

Дальше:
  1) Откройте FreePBX GUI и заведите добавочные (Applications -> Extensions, PJSIP),
     затем Apply Config.
  2) Выгрузите их в realtime-таблицы для secondary-узлов:
       /usr/local/bin/asterisk-cluster-sync --apply
  3) На каждом secondary выполните:
       ./scripts/clone-node.sh --node-name=<имя> --node-ip=<ip> \\
         --master-ip=$NODE_IP --peers=$PEERS --cluster-name=$CLUSTER_NAME \\
         --sst-pass='<SST_PASS выше>' --rt-pass='<RT_PASS выше>'
  4) Сгенерируйте межузловые транки на ВСЕХ узлах:
       ./scripts/make-node-trunks.sh --peers-map=$NODE_NAME=$NODE_IP,<имя>=<ip>
  5) Проверьте кворум: docs/05-operations.md

EOF
