# Asterisk-кластер на 5 площадок

Отказоустойчивая телефония: одна база, единая нумерация и транки, локальная
регистрация абонентов с автоматическим переключением на мастер при отказе
площадки.

Всё бесплатное: MariaDB Galera, Asterisk/FreePBX community, собственный
сервер автопровижининга. Без платного Endpoint Manager и облачных сервисов
вендоров.

```
┌──────────────────────────────────────────────────────────────┐
│  MariaDB Galera — общая база на всех площадках               │
│  номера · транки · учётки · регистрации (ps_contacts)        │
└───┬──────────┬──────────┬──────────┬──────────┬──────────────┘
    │          │          │          │          │
┌───┴───┐  ┌───┴───┐  ┌───┴───┐  ┌───┴───┐  ┌───┴───┐
│мастер │  │площад.│  │площад.│  │площад.│  │площад.│
│FreePBX│◄─┤   1   ├──┤   2   ├──┤   3   ├──┤   4   │  межузловые
│  GUI  │  └───┬───┘  └───┬───┘  └───┬───┘  └───┬───┘  транки
└───┬───┘      │          │          │          │
    │ backup   │ primary  │          │          │
    └──────────┴──── телефоны ───────┴──────────┘
```

Абонент звонит на номер — узел смотрит в общей базе, на какой площадке этот
номер сейчас зарегистрирован, и либо звонит локально, либо ведёт вызов туда
по межузловому транку. Если площадка недоступна, телефон сам
перерегистрируется на мастер за 10–60 секунд и продолжает работать.

## Быстрый старт

Стенд из двух серверов на Debian 12:

```bash
git clone https://github.com/IIPOCTO4EJIOBEK/Asterisk-claster.git /opt/asterisk-cluster
cd /opt/asterisk-cluster

# 1. Проверка готовности (на обоих серверах, ничего не меняет)
./scripts/preflight.sh --node-ip=10.10.10.11 --peers=10.10.10.11,10.10.10.12

# 2. Мастер
./scripts/install-master.sh --node-name=master --node-ip=10.10.10.11 \
    --peers=10.10.10.11,10.10.10.12 --cluster-name=asterisk_lab

# 3. Площадка (пароли — из вывода шага 2)
./scripts/clone-node.sh --node-name=site-1 --node-ip=10.10.10.12 \
    --master-ip=10.10.10.11 --master-node-name=master \
    --peers=10.10.10.11,10.10.10.12 --cluster-name=asterisk_lab \
    --asterisk-major=21 --sst-pass='...' --rt-pass='...'

# 4. Межузловые транки — на обоих узлах
./scripts/make-node-trunks.sh --peers-map=master=10.10.10.11,site-1=10.10.10.12

# 5. Завести номера в FreePBX GUI, затем на мастере:
asterisk-cluster-sync --apply
asterisk-cluster-push-dialplan --nodes=site-1=10.10.10.12
```

Подробно, с чек-листом приёмки: [docs/02-lab-deploy.md](docs/02-lab-deploy.md).

## Документация

| Документ | О чём |
|---|---|
| [01-architecture.md](docs/01-architecture.md) | Как устроено и почему именно так |
| [02-lab-deploy.md](docs/02-lab-deploy.md) | Стенд на двух серверах + приёмка |
| [03-provisioning.md](docs/03-provisioning.md) | Автопровижининг и его модель угроз |
| [04-production-rollout.md](docs/04-production-rollout.md) | Ввод реальных площадок |
| [05-operations.md](docs/05-operations.md) | Эксплуатация, мониторинг, бэкапы |
| [06-troubleshooting.md](docs/06-troubleshooting.md) | Разбор неполадок по симптомам |
| [07-security.md](docs/07-security.md) | Секреты, периметр, что не сделано |
| [08-changes-from-draft.md](docs/08-changes-from-draft.md) | Что исправлено против черновика |

## Состав

```
scripts/
  preflight.sh           проверка сервера до установки (RTT, ресурсы, порты)
  install-master.sh      мастер: FreePBX + Galera + realtime + провижининг
  clone-node.sh          площадка: join в Galera + headless Asterisk
  install-garbd.sh       арбитр кворума (на отдельном хосте)
  make-node-trunks.sh    межузловые транки, полная сетка
  sync-config.py         номера из FreePBX -> realtime-таблицы ps_*
  push-dialplan.sh       диалплан с мастера -> площадки
  healthcheck.sh         состояние узла, метрики Prometheus
  galera-recover.sh      восстановление кворума
  lint.sh                статические проверки

config/                  шаблоны конфигураций (Galera, ODBC, PJSIP, диалплан)
provisioning/            сервер автопровижининга: PHP + шаблоны вендоров
sql/                     схема провижининга, аудит совместимости с Galera
```

## Как конфигурация попадает на площадки

Два разных пути, и это не случайность:

| Что | Как | Когда запускать |
|---|---|---|
| Номера, учётки, AOR | realtime-таблицы `ps_*` | `asterisk-cluster-sync --apply` после Apply Config |
| Диалплан, IVR, очереди | rsync файлов | `asterisk-cluster-push-dialplan` после Apply Config |
| Регистрации телефонов | общая таблица `ps_contacts` | автоматически |

FreePBX **не заполняет** таблицы `ps_*` сам — он рендерит статические файлы.
`sync-config.py` читает их и переносит в realtime. Это ключевой момент,
без которого площадки не увидят ни одного абонента.

## Требования

- Debian 12 (bookworm) на всех узлах
- Мастер: 2 vCPU / 4 GB / 20 GB, площадка: 2 vCPU / 2 GB / 20 GB
- RTT между площадками до 20 мс (до 50 мс терпимо) — Galera подтверждает
  запись синхронно, задержка входит в время транзакции
- Site-to-site VPN или L2 между площадками
- Одинаковая мажорная версия Asterisk на всех узлах

## Разработка

```bash
./scripts/lint.sh
```

Проверяет синтаксис bash/PHP/Python, отсутствие паролей по умолчанию и то,
что каждая переменная в шаблонах кем-то задаётся. То же самое гоняется в CI
на каждый push.

## Статус

Комплект собран и проверен статически; развёртывание на живом железе —
следующий шаг. Перед боем обязательно пройдите чек-лист приёмки из
[docs/02-lab-deploy.md](docs/02-lab-deploy.md) и список
«что осталось нерешённым» в
[docs/08-changes-from-draft.md](docs/08-changes-from-draft.md).
