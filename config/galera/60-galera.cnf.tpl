# /etc/mysql/mariadb.conf.d/60-galera.cnf
# Генерируется scripts/install-master.sh и scripts/clone-node.sh — правки
# вручную будут перезаписаны при следующем прогоне (бэкап делается рядом).

[mysqld]
# Galera требует InnoDB и ROW-репликацию.
binlog_format=ROW
default_storage_engine=InnoDB
innodb_autoinc_lock_mode=2

# Компромисс: 0 — максимальная скорость, но при падении узла теряется до
# секунды его локальных транзакций (данные при этом остаются в кластере на
# других узлах). Для одиночного узла или кластера из двух узлов ставьте 2.
innodb_flush_log_at_trx_commit=2

# Слушаем на всех интерфейсах: доступ ограничивается firewall'ом, а не
# bind-address. Файл 60-* грузится после стокового 50-server.cnf, поэтому
# именно это значение и будет действующим.
bind-address=0.0.0.0

# ps_contacts обновляется на каждой регистрации/qualify — короткие таймауты
# ожидания блокировок лучше, чем длинные очереди.
innodb_lock_wait_timeout=15

[galera]
wsrep_on=ON
wsrep_provider=/usr/lib/galera/libgalera_smm.so
wsrep_cluster_name="{{CLUSTER_NAME}}"

# Полный список узлов кластера — одинаковый на всех нодах.
wsrep_cluster_address="gcomm://{{PEERS}}"

wsrep_node_address="{{NODE_IP}}"
wsrep_node_name="{{NODE_NAME}}"

# mariabackup — единственный метод SST, не блокирующий донора на запись.
wsrep_sst_method=mariabackup
wsrep_sst_auth={{SST_USER}}:{{SST_PASS}}

# Число потоков применения репликации. По ядрам, но не больше 8:
# на телефонии транзакции мелкие, выигрыш от большего числа исчезает.
wsrep_slave_threads={{WSREP_SLAVE_THREADS}}

# Читать со своей ноды только то, что уже применено. Без этого свежесозданный
# в FreePBX добавочный может секунду-другую не находиться на другом узле.
# 1 = ждать применения перед SELECT.
wsrep_sync_wait=1

# Таймауты gcomm под WAN между площадками: дефолты рассчитаны на LAN и
# на межгороде дают ложные разрывы кластера.
wsrep_provider_options="evs.keepalive_period=PT3S;evs.inactive_check_period=PT10S;evs.suspect_timeout=PT30S;evs.inactive_timeout=PT60S;evs.install_timeout=PT60S;gcache.size={{GCACHE_SIZE}}"

# Логировать конфликты сертификации — первый признак того, что таблица
# ps_contacts пишется слишком часто (см. docs/05-operations.md).
wsrep_log_conflicts=ON
