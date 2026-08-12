# Дамп PBX 10.1.10.111 (Debian 11, FreePBX 16, Asterisk 18.26.1)

Полный дамп конфигурации телефонии с сервера 10.1.10.111 для разработки и развёртывания.

## Состав

- **sql/** — дампы БД FreePBX:
  - `asterisk-db.sql` — база `asterisk` (транки, IVR, extensions, endpointman_model_list, kvstore FreePBX)
  - `asteriskcdrdb-schema.sql` — схема CDR (без данных, CDR на 129MB не включён)
- **etc-asterisk/** — `/etc/asterisk` (все конфиги: pjsip, extensions_additional, cdr_*, res_odbc, manager и т.д.)
- **modules/** — модули:
  - `ossepm16.tgz` — установочный пакет OSS Endpoint Manager 16.0.0 (md5 65a7ef2908523df77844bd424c8ad198)
  - `endpointman.tar.gz` — распакованный модуль endpointman из `/var/www/html/admin/modules/`
- **scripts/** — скрипты мониторинга Zabbix (`zabbix_asterisk_collect`, `zabbix_asterisk_metric` + бэкапы)

## Что НЕ вошло

- `/etc/asterisk/keys/*` — сертификаты и ключи (default.pem, default.crt, aster.*, integration/*, _account/*)
- Данные CDR (только схема)
- `user-images/`, `models/` (если есть) — веса

## Доступ

- SSH: vardo001@10.1.10.111
- FreePBX: http://10.1.10.111/admin
- БД: `freepbxuser` (креды в `/etc/asterisk/res_odbc_additional.conf`), базы `asterisk`, `asteriskcdrdb`
- Транки: SIP-RTK (Ростелеком), SIP-MANGO (Манго)

## Секреты замаскированы

Пароли в этом дампе заменены на `__MASKED__` инструментом
[`tools/mask-secrets.py`](../tools/mask-secrets.py) — 2617 значений:

| Что | Сколько | Где |
|---|---|---|
| SIP-пароли абонентов | 444 (+319 в `secret_origional`) | `sql/asterisk-db.sql`, таблица `sip` |
| Хеши паролей UCP | 462 | таблица `userman_users` |
| Учётки транков | 3 | таблица `pjsip` |
| Пароли AMI | 2 | `manager.conf`, `manager_additional.conf` |
| Пароль БД `freepbxuser` | 1 | `res_odbc_additional.conf` |
| Учётки в диалплане и панелях | 5 | `extensions_additional.conf`, `cxpanel` |

Сохранено без изменений: номера добавочных, имена, схема нумерации, все
настройки PJSIP, диалплан, транки, шаблоны провижининга Endpoint Manager
(переменные вида `{$secret}` — плейсхолдеры шаблонов, а не пароли).
В `keys/` только `.csr` — запросы на сертификат, приватных ключей нет.

Дамп остаётся пригодным для разработки: SQL разворачивается, конфиги
валидны. Для стенда подставьте свои пароли вместо `__MASKED__`.

> **Пароли считать скомпрометированными.** Дамп какое-то время находился в
> публичном репозитории с рабочими значениями. Маскирование убирает их из
> текущего состояния, но не отменяет ротацию: смените SIP-пароли абонентов,
> учётки транков у Ростелекома и Манго, пароли AMI и `freepbxuser`.
