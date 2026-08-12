# Эксплуатация

## Ежедневные операции

### После каждого Apply Config в FreePBX

```bash
asterisk-cluster-sync --apply
asterisk-cluster-push-dialplan --nodes=voronezh=10.4.3.6,slavyansk=10.5.1.4
```

Без первой команды новые номера не появятся на площадках. Без второй не
доедут изменения IVR, очередей и расписаний.

Сначала стоит посмотреть план без записи — команда без `--apply` показывает,
что будет добавлено, изменено и удалено:

```
    ps_endpoints: +2 ~14 -1
```

Строка `-1` означает, что номер удалён в FreePBX и будет удалён из realtime.
Если цифры выглядят неожиданно (например, `-200`), не применяйте: скорее
всего, FreePBX не отрендерил конфиги или Apply Config не был нажат.

### Автоматическая раскатка

Чтобы не помнить про это руками, повесьте на хук FreePBX:

```bash
cat >/etc/asterisk/freepbx_post_apply.sh <<'EOF'
#!/bin/bash
/usr/local/bin/asterisk-cluster-sync --apply --quiet
/usr/local/bin/asterisk-cluster-push-dialplan \
  --nodes=voronezh=10.4.3.6,slavyansk=10.5.1.4 >/var/log/cluster-push.log 2>&1
EOF
chmod +x /etc/asterisk/freepbx_post_apply.sh
fwconsole setting POST_RELOAD_HOOK /etc/asterisk/freepbx_post_apply.sh
```

Для `push-dialplan` нужен беспарольный SSH с мастера на площадки:

```bash
ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519    # один раз на мастере
ssh-copy-id root@10.4.3.6                              # на каждую площадку
```

## Мониторинг

### Health-check

Стоит на каждом узле, запускается таймером раз в минуту:

```bash
asterisk-cluster-health           # подробно
asterisk-cluster-health --quiet   # только проблемы
systemctl status asterisk-cluster-health.timer
journalctl -u asterisk-cluster-health --since '1 hour ago'
```

Коды возврата: `0` — норма, `1` — есть проблемы, `2` — узел выпал из
кластера и требует вмешательства.

### Prometheus

```bash
asterisk-cluster-health --prom
```

Пишет в `/var/lib/node_exporter/textfile_collector/asterisk_cluster.prom`
метрики: размер кластера, признак Synced, число endpoint'ов и контактов,
доступность межузловых транков, число проблем.

Алерты, которые стоит завести в первую очередь:

| Условие | Смысл |
|---|---|
| `asterisk_cluster_synced == 0` | узел выпал из синхронизации |
| `asterisk_cluster_galera_size < N` | площадка отвалилась от кластера |
| `asterisk_cluster_node_trunks_available < N-1` | нет связи с площадкой |
| `asterisk_cluster_contacts` резко упало | массовая потеря регистраций |

### Что смотреть руками

```sql
-- Кто где зарегистрирован прямо сейчас
SELECT reg_server AS площадка, COUNT(*) AS телефонов
FROM ps_contacts GROUP BY reg_server;
```

Если у какой-то площадки резко выросло число телефонов, а у соседней упало —
там произошёл failover, и стоит выяснить почему.

```sql
-- Контакты без reg_server: межузловая маршрутизация к ним не работает
SELECT endpoint FROM ps_contacts WHERE reg_server IS NULL OR reg_server = '';
```

Пустой `reg_server` означает, что на узле не задан `systemname`. Лечится
в `/etc/asterisk/asterisk.conf` и рестартом Asterisk.

## Восстановление кворума

Симптом: `healthcheck` пишет `компонент non-Primary`, БД не принимает
запросы, звонки на площадке не проходят.

```bash
./scripts/galera-recover.sh --status
```

Скрипт покажет состояние и подскажет режим. Кратко:

**Узел жив, но в меньшинстве** (обрыв связи между площадками). Сравните
`wsrep_last_committed` на всех доступных узлах и на том, где значение
наибольшее:

```bash
./scripts/galera-recover.sh --promote
```

**Кластер погашен целиком.** На каждом узле посмотрите `seqno`:

```bash
cat /var/lib/mysql/grastate.dat
mariadbd --wsrep-recover      # если seqno = -1
```

На узле с наибольшим `seqno`:

```bash
./scripts/galera-recover.sh --bootstrap
```

Остальные потом обычным `systemctl start mariadb`.

> **Никогда не делайте promote или bootstrap на двух узлах одновременно.**
> Получится split-brain: два кластера с расходящимися данными, слияние
> вручную и потеря части изменений.

## Бэкапы

Galera — это отказоустойчивость, а не резервная копия. Ошибочный
`DELETE FROM ps_endpoints` реплицируется на все пять площадок за
миллисекунды.

```bash
# Полный бэкап на мастере, ежедневно
mariabackup --backup --target-dir=/var/backups/mariadb/$(date +%F) \
            --user=root

# Логический дамп — им проще откатить одну таблицу
mysqldump --single-transaction --routines --triggers \
          asterisk | gzip > /var/backups/asterisk-$(date +%F).sql.gz
```

Отдельно бэкапится состояние FreePBX (`fwconsole backup`) — в нём модули,
настройки GUI и то, чего нет в realtime-таблицах.

**Бэкап, который не восстанавливали, бэкапом не является.** Раз в квартал
разворачивайте копию на отдельной VM и проверяйте, что она поднимается.

## CDR вне Galera

Таблица `cdr` не имеет первичного ключа и пишется на каждый звонок.
Реплицировать её синхронно на пять площадок — это лишняя нагрузка ради
данных, которые нужны только для отчётов.

Рекомендуемая схема: `asteriskcdrdb` вынести из кластера (оставить локальной
на каждом узле), а для отчётности собирать их в отдельную базу-агрегатор
асинхронной репликацией или ночным сливом.

Проверить, что попало в репликацию:

```sql
SOURCE sql/02-galera-audit.sql
```

## Обновление Asterisk

Мажорную версию обязаны иметь одинаковую все узлы: набор колонок `ps_*`
между версиями различается.

Порядок:

1. Обновить **тестовый стенд**, прогнать приёмку из
   [02-lab-deploy.md](02-lab-deploy.md).
2. Снять бэкап базы и конфигураций.
3. Обновить площадки по одной, дожидаясь `Synced` и проверяя звонки.
4. Обновить мастер последним.
5. Прогнать `asterisk-cluster-sync` — схема могла получить новые колонки.

Между шагами 3 и 4 кластер работает на разных версиях. Это допустимо
короткое время, но не как постоянный режим.

## Плановые работы на площадке

```bash
# 1. Мягко выгнать телефоны на резервный сервер
asterisk -rx "pjsip send unregister <endpoint>"   # или просто остановить Asterisk
systemctl stop asterisk

# 2. Убедиться, что они ушли на мастер
#    (на мастере)
asterisk -rx "pjsip show contacts" | grep -c Avail

# 3. Работы...

# 4. Вернуть
systemctl start asterisk
asterisk-cluster-health
```

Останавливать MariaDB на площадке при работающем Asterisk не нужно: он
потеряет realtime и перестанет обслуживать вызовы. Сначала Asterisk, потом БД.

## Ротация паролей

Пароли лежат в `/etc/asterisk-cluster/cluster.env` (0600) на каждом узле.

```bash
# Пароль realtime-пользователя
mysql -e "ALTER USER 'asterisk_rt'@'%' IDENTIFIED BY 'новый';"
# на КАЖДОМ узле:
sed -i "s/^RT_PASS=.*/RT_PASS=новый/" /etc/asterisk-cluster/cluster.env
sed -i "s/^password => .*/password => новый/" /etc/asterisk/res_odbc.conf
asterisk -rx "module reload res_odbc.so"
```

Секрет HMAC провижининга меняется в
`/etc/asterisk-cluster/provisioning.php`; после смены все ранее выданные
персональные токены становятся недействительны — телефонам понадобятся новые
URL.
