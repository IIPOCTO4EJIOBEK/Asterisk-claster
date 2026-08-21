# Asterisk-кластер на 5 площадок

Отказоустойчивая телефония: одна база, единая нумерация и транки, локальная
регистрация абонентов с автоматическим переключением на мастер при отказе
площадки.

Всё бесплатное: MariaDB Galera, Asterisk/FreePBX community, OSS PBX End
Point Manager для автопровижининга. Без платного Sangoma Endpoint Manager и
облачных RPS-сервисов вендоров.

Существующая АТС не переустанавливается — она становится мастером как есть,
вместе с номерами, диалпланом, транками и уже настроенным провижинингом.

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

Два пути. Выбор зависит от того, есть ли уже работающая АТС.

### А. У вас уже есть FreePBX (рекомендуется)

Существующая АТС становится мастером **без переустановки**: номера, диалплан,
транки, модули и OSS Endpoint Manager остаются на месте.

```bash
git clone https://github.com/IIPOCTO4EJIOBEK/Asterisk-claster.git /opt/asterisk-cluster
cd /opt/asterisk-cluster

# 1. На существующей АТС — снимает бэкап, переводит БД в Galera, включает realtime
./scripts/adopt-master.sh --node-name=rostov --node-ip=10.1.10.111 \
    --peers=10.1.10.111,10.4.3.6 --cluster-name=asterisk_prod

# 2. Выгрузить номера в realtime, чтобы их увидели площадки
asterisk-cluster-sync --apply

# 3. Площадка (пароли — из вывода шага 1)
./scripts/clone-node.sh --node-name=voronezh --node-ip=10.4.3.6 \
    --master-ip=10.1.10.111 --master-node-name=rostov \
    --peers=10.1.10.111,10.4.3.6 --cluster-name=asterisk_prod \
    --asterisk-major=18 --sst-pass='...' --rt-pass='...'

# 4. Межузловые транки — на ВСЕХ узлах
./scripts/make-node-trunks.sh --peers-map=rostov=10.1.10.111,voronezh=10.4.3.6

# 5. Failover телефонов через ваш Endpoint Manager
epm-set-site --sites sites.conf --apply --rebuild
```

Шаг 5 требует однократной правки шаблона — резервный сервер EPM из коробки
не выдаёт: [docs/09-epm-integration.md](docs/09-epm-integration.md).

### Б. Установка с нуля

Для лабораторного стенда на чистых серверах Debian 12 — `install-master.sh`
вместо шага 1, подробно в [docs/02-lab-deploy.md](docs/02-lab-deploy.md).

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
| [09-epm-integration.md](docs/09-epm-integration.md) | OSS Endpoint Manager: failover через штатный провижининг |
| [10-production-hardening.md](docs/10-production-hardening.md) | Аудит боевой АТС, усиление, приёмка перед вводом |
| [11-local-trunks.md](docs/11-local-trunks.md) | Свой транк провайдера на каждой площадке |
| [12-rollout-schedule.md](docs/12-rollout-schedule.md) | План внедрения: семь узлов, центр в ЦОД, 16 недель |
| [plan/](docs/plan/) | Единый номерной план: CSV, sites.conf, отчёт |
| [plan/index.html](docs/plan/index.html) | Страница проекта: описание, нумерация, настройка |
| [plan/scheme.html](docs/plan/scheme.html) | Схемы работы кластера: четыре механизма и сценарии отказов |
| [plan/rollout.html](docs/plan/rollout.html) | План страницей: итоговая схема, гант на 16 недель, вехи, риски |
| [plan/dit-annual-plan.xlsx](docs/plan/dit-annual-plan.xlsx) | План в шаблоне годового плана работ ДИТ |
| [plan/dit-project-registry.xlsx](docs/plan/dit-project-registry.xlsx) | План в шаблоне реестра проектов плана автоматизации |

## Состав

```
scripts/
  preflight.sh           проверка сервера до установки (RTT, ресурсы, порты)
  adopt-master.sh        существующая АТС -> мастер кластера, без переустановки
  install-master.sh      мастер с нуля: FreePBX + Galera + realtime
  clone-node.sh          площадка с нуля: join в Galera + headless Asterisk
  prepare-clone.sh       клон ВМ мастера -> самостоятельный узел кластера
  install-garbd.sh       арбитр кворума (на отдельном хосте)
  make-node-trunks.sh    межузловые транки, полная сетка
  sync-config.py         номера из FreePBX -> realtime-таблицы ps_*
  push-dialplan.sh       диалплан с мастера -> площадки
  healthcheck.sh         состояние узла, метрики Prometheus
  galera-recover.sh      восстановление кворума
  epm-set-site.py        привязка телефонов Endpoint Manager к площадкам
  harden.sh              журнал безопасности, fail2ban, ограничение AMI
  setup-local-trunk.sh   транк провайдера на площадке + откат на мастер
  check-numbering.py     конфликты нумерации между АТС до объединения
  update-peers.sh        список узлов с проверкой кворума и ожиданием Synced
  setup-standby-master.sh резервный мастер: prepare / status / promote / demote
  build-numbering-plan.py единый номерной план из таблицы аудита
  build-dit-plan.py      план внедрения в корпоративных шаблонах ДИТ (xlsx)
  lint.sh                статические проверки

tools/
  mask-secrets.py        маскирование учётных данных в дампах боевых АТС

config/                  шаблоны конфигураций (Galera, ODBC, PJSIP, диалплан)
provisioning/            запасной сервер провижининга (если EPM не подходит)
sql/                     схема провижининга, ps_contacts, аудит под Galera
pbx1-10.1.10.111/        дамп боевой АТС для разработки (пароли замаскированы)
```

## Как конфигурация попадает на площадки

Два разных пути, и это не случайность:

| Что | Как | Когда запускать |
|---|---|---|
| Номера, учётки, AOR | realtime-таблицы `ps_*` | `asterisk-cluster-sync --apply` после Apply Config |
| Диалплан, IVR, очереди | rsync файлов | `asterisk-cluster-push-dialplan` после Apply Config |
| Регистрации телефонов | общая таблица `ps_contacts` | автоматически |
| Основной/резервный сервер телефона | Endpoint Manager | `epm-set-site --apply --rebuild` |

FreePBX **не заполняет** таблицы `ps_*` сам — он рендерит статические файлы.
`sync-config.py` читает их и переносит в realtime. Это ключевой момент,
без которого площадки не увидят ни одного абонента.

## Требования

- **Мастер**: любая работающая связка FreePBX + Asterisk 18/20/21 на Debian
  11 или 12. Переустановка не требуется — `adopt-master.sh` работает поверх.
- **Площадки**: Debian 12 (bookworm), чистая установка. Мажорная версия
  Asterisk обязана совпадать с мастером — скрипт это проверяет.
- Мастер: 2 vCPU / 4 GB / 20 GB, площадка: 2 vCPU / 2 GB / 20 GB
- RTT между площадками до 20 мс (до 50 мс терпимо) — Galera подтверждает
  запись синхронно, задержка входит в время транзакции
- Site-to-site VPN или L2 между площадками
- Одинаковая мажорная версия Asterisk на всех узлах

## Разработка

```bash
./tests/run-all.sh
```

Ни БД, ни Asterisk для тестов не нужны. Проверяется:

- синтаксис bash/PHP/Python, shellcheck, отсутствие паролей по умолчанию,
  что каждая переменная в шаблонах кем-то задаётся (`scripts/lint.sh`);
- рендер конфигураций: подстановка значений со спецсимволами, отказ при
  незаданной переменной, резервные копии, идемпотентность (`test-render.sh`);
- парсер конфигов PJSIP: наследование шаблонов и накопительные опции
  (`test-parser.py`);
- провижининг: нормализация MAC, проверка подсетей на границах масок,
  рендер шаблонов всех трёх вендоров и наличие включённого failover
  (`test-provisioning.php`).

То же самое гоняется в CI на каждый push.

## Статус

Комплект собран, проверен статически и тестами; на живом железе не
разворачивался. Порядок ввода в эксплуатацию, аудит существующей АТС и
чек-лист приёмки — в
[docs/10-production-hardening.md](docs/10-production-hardening.md).

Что осознанно осталось за рамками (мастер как единственная точка
управления, локальные транки на площадках, TLS/SRTP, шифрование
репликации) — перечислено там же и в
[docs/08-changes-from-draft.md](docs/08-changes-from-draft.md).
