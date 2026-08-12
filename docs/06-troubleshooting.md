# Разбор неполадок

Диагностика от симптома. Начинать всегда с `asterisk-cluster-health` — он
проверяет всё перечисленное ниже за одну секунду.

## Узел не присоединяется к кластеру

`clone-node.sh` завершился с «Узел не синхронизировался».

```bash
journalctl -u mariadb -n 200 --no-pager
```

| В журнале | Причина | Что делать |
|---|---|---|
| `failed to open gcomm backend connection` | не видно порт 4567 на мастере | проверить firewall и маршрутизацию |
| `SST failed`, `access denied for user 'sst_user'` | не совпал пароль SST | сверить `--sst-pass` с `/etc/asterisk-cluster/cluster.env` мастера |
| `WSREP: Failed to prepare for incremental state transfer` | это нормально при первом входе, дальше пойдёт полный SST | ждать |
| `Cluster name mismatch` | разные `--cluster-name` | привести к одному |
| зависло на `Joining: receiving State Transfer` | база большая, SST идёт | ждать; скорость видна по росту `/var/lib/mysql` |

Проверить пользователя SST на мастере:

```bash
mysql -e "SELECT User, Host FROM mysql.user WHERE User='sst_user';"
mysql -e "SHOW GRANTS FOR 'sst_user'@'localhost';"
```

Нужны права `RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR`.

## На площадке не видно номеров

`pjsip show endpoints` пусто, хотя в FreePBX номера есть.

Проверять по порядку — в 90% случаев дело в первых двух пунктах.

**1. Синхронизация вообще запускалась?**

```sql
SELECT COUNT(*) FROM ps_endpoints;
```

Если 0 — на мастере не выполнялся `asterisk-cluster-sync --apply`. Это самая
частая причина: FreePBX **не заполняет** `ps_*` сам, он рендерит статические
файлы.

**2. ODBC подключён?**

```bash
asterisk -rx "odbc show all"
```

Должно быть `Number of active connections: 1` или больше. Если нет:

```bash
# имя драйвера в /etc/odbc.ini должно точно совпадать с секцией в odbcinst.ini
odbcinst -q -d
grep Driver /etc/odbc.ini

# проверка соединения напрямую
isql -v asterisk-galera asterisk_rt '<пароль>'
```

Классическая ошибка — `Driver = MariaDB`, тогда как пакет регистрирует
драйвер как `MariaDB Unicode`.

**3. Sorcery настроен?**

```bash
grep -A5 res_pjsip /etc/asterisk/sorcery.conf
```

Без секции `[res_pjsip]` с `endpoint=realtime,ps_endpoints` PJSIP не пойдёт
в базу, даже если `extconfig.conf` заполнен.

**4. Модули загрузились в нужном порядке?**

```bash
asterisk -rx "module show like res_config_odbc"
grep preload /etc/asterisk/modules.conf
```

`res_odbc.so` и `res_config_odbc.so` должны быть в `preload`.

**5. Права пользователя БД?**

```sql
SHOW GRANTS FOR 'asterisk_rt'@'%';
```

## Звонок между площадками не проходит

**Симптом: «абонент недоступен», хотя телефон зарегистрирован.**

```sql
SELECT endpoint, reg_server, expiration_time FROM ps_contacts;
```

- **Таблица пуста, хотя телефоны зарегистрированы** → `ps_contacts` не в
  realtime. Проверьте `extconfig.conf` и `sorcery.conf`: должно быть
  `contact=realtime,ps_contacts` в `[res_pjsip_registrar]`.
- **`reg_server` пуст** → на узле не задан `systemname`:
  ```bash
  grep systemname /etc/asterisk/asterisk.conf
  ```
  Без него диалплан не знает, куда вести вызов. После правки — рестарт
  Asterisk (не reload).
- **`reg_server` заполнен, но звонок не идёт** → проблема в транках:
  ```bash
  asterisk -rx "pjsip show aors" | grep node-
  asterisk -rx "pjsip show contacts" | grep node-    # ждём Avail
  ```
  Если транка нет — не запускался `make-node-trunks.sh` на этом узле.
  Если `Unavail` — площадка не отвечает на OPTIONS: сеть или firewall.

**Проверить, что решает диалплан:**

```bash
asterisk -rx "console set verbose 3"
# позвонить и смотреть NoOp-строки:
#   Cluster dial 720 from node voronezh
#   Contact node for 720: 'rostov'
#   Routing 720 to node rostov
```

**Проверить запрос к БД напрямую:**

```bash
asterisk -rx "dialplan show cluster-dial"
asterisk -rx "odbc show all"
```

## Телефон не переключается на резервный сервер

- Проверьте, что в выданном конфиге вообще есть второй сервер:
  ```bash
  curl -sk "https://<мастер>:8443/prov/<mac>.cfg?t=<токен>" | grep -i sip_server
  ```
- Для Yealink нужен не только `sip_server.2.address`, но и
  `fallback.redundancy_type = 1`. Один лишь второй адрес не включает failover.
- `phonectl list` — есть ли у телефона `backup_server` в базе.
- Переключение занимает `retry_interval` × число попыток, обычно 10–60 с.
  Если ждали 5 секунд — подождите ещё.

## Телефон не возвращается на свою площадку

Работает, но через мастер. Причина — не включён failback:

- Yealink: `account.1.failback_mode = 1` и `fallback.timeout`
- Fanvil: `SIP1 Enable Failback :1`
- Grandstream: `P2333 = 1`

Всё это уже есть в шаблонах; если телефон получал конфиг раньше — выдайте
заново (`phonectl arm` и перезагрузка телефона).

## Провижининг отвечает ошибкой

```bash
phonectl log --limit=20
```

| `result` | Что значит | Решение |
|---|---|---|
| `denied_network` | адрес вне `allowed_cidrs` | телефон не в той подсети либо неверный `--phone-cidr` |
| `denied_token` | нет или неверный токен | `phonectl url <mac>` даст правильный URL |
| `window_closed` | окно провижининга закрыто | `phonectl arm <mac> --minutes=30` |
| `unknown_mac` | телефона нет в базе | `phonectl add ...` |
| `no_auth` | нет записи в `ps_auths` | номер не создан либо не выполнялся `asterisk-cluster-sync --apply` |
| `empty_password` | у добавочного пустой пароль | в FreePBX проверить `auth_type = userpass` |

**502 Bad Gateway** — не поднялся php-fpm или неверный путь к сокету:

```bash
systemctl status 'php*-fpm'
ls -l /run/php/
grep fastcgi_pass /etc/nginx/sites-available/provisioning
```

**Ничего не пишется в журнал** — запрос не дошёл до PHP:

```bash
tail -f /var/log/nginx/provisioning-access.log
tail -f /var/log/nginx/provisioning-error.log
```

## Кластер тормозит, звонки устанавливаются медленно

```sql
SHOW STATUS LIKE 'wsrep_flow_control_paused';
SHOW STATUS LIKE 'wsrep_local_recv_queue_avg';
SHOW STATUS LIKE 'wsrep_local_cert_failures';
```

- `wsrep_flow_control_paused` > 0.1 — какой-то узел не успевает применять
  репликацию и тормозит весь кластер. Обычно это медленный диск на одной
  площадке или узкий канал.
- Растут `wsrep_local_cert_failures` — конфликты сертификации. На телефонии
  почти всегда означает слишком частую запись в `ps_contacts`: увеличьте
  `register_expires` (см. [03-provisioning.md](03-provisioning.md)) и
  `qualify_frequency` в AOR.

Найти узкое место:

```bash
# на каждом узле
mysql -e "SHOW STATUS LIKE 'wsrep_local_recv_queue_avg';"
```

Узел с наибольшим значением и есть тормоз.

## Asterisk не стартует после правки конфигов

```bash
journalctl -u asterisk -n 100 --no-pager
asterisk -cvvvvv          # запуск в консоли, видно все ошибки загрузки
```

Все скрипты делают резервную копию перед перезаписью:

```bash
ls -lt /etc/asterisk/*.bak.* | head
cp /etc/asterisk/pjsip.conf.bak.20260812-143000 /etc/asterisk/pjsip.conf
```

## Полезные однострочники

```bash
# Состояние кластера со всех узлов разом
for n in 10.10.10.11 10.4.3.6 10.5.1.4; do
  echo "=== $n ==="
  ssh root@$n "mysql -e \"SHOW STATUS LIKE 'wsrep_cluster_size';
    SHOW STATUS LIKE 'wsrep_local_state_comment';\""
done

# Сколько телефонов на какой площадке
mysql asterisk -e "SELECT reg_server, COUNT(*) FROM ps_contacts GROUP BY reg_server;"

# Расхождение схемы между узлами (должно быть пусто)
for n in 10.10.10.11 10.4.3.6; do
  ssh root@$n "mysql -N -e \"SELECT COUNT(*) FROM information_schema.columns
    WHERE table_schema='asterisk' AND table_name='ps_endpoints';\""
done

# Кто дёргал провижининг за сутки
mysql asterisk -e "SELECT result, COUNT(*) FROM provision_log
  WHERE ts > NOW() - INTERVAL 1 DAY GROUP BY result;"
```
