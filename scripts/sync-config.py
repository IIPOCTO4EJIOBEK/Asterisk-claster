#!/usr/bin/env python3
"""
sync-config.py — выгружает конфигурацию PJSIP, сгенерированную FreePBX на
мастере, в realtime-таблицы ps_*, из которых её читают secondary-узлы.

Зачем это нужно
---------------
В черновике утверждалось, что FreePBX по кнопке Apply Config заполняет
ps_endpoints / ps_aors / ps_auths. Это не так: FreePBX хранит добавочные в
СВОИХ таблицах и рендерит из них статические файлы /etc/asterisk/pjsip.*.conf.
Таблицы ps_* (alembic-схема Asterisk realtime) при этом остаются пустыми, и
secondary-узлы не видят ни одного абонента.

Этот скрипт закрывает разрыв: читает то, что FreePBX уже отрендерил, и
переносит в realtime-таблицы. Источник правды остаётся один — GUI мастера.

Устойчивость к версиям
----------------------
Набор колонок ps_* отличается между мажорными версиями Asterisk. Скрипт не
знает схему заранее: он спрашивает information_schema и переносит только те
опции, для которых в таблице есть колонка. Неизвестные опции пропускаются с
предупреждением, а не роняют синхронизацию.

Использование
-------------
    ./sync-config.py                 # показать план, ничего не менять
    ./sync-config.py --apply         # применить
    ./sync-config.py --apply --quiet # для cron/systemd

Таблицы ps_endpoints, ps_aors, ps_auths и ps_endpoint_id_ips считаются
целиком принадлежащими этому скрипту: строки, исчезнувшие из конфигурации
FreePBX, из них удаляются.

Две таблицы не трогаются никогда:
  ps_contacts      — живые регистрации телефонов, ими управляет Asterisk;
  ps_registrations — регистрации на транки провайдеров, они у каждой
                     площадки свои (docs/11-local-trunks.md).
"""

import argparse
import os
import re
import sys


def _pymysql():
    """Драйвер БД импортируется лениво: разбор конфигов от него не зависит,
    и парсер остаётся тестируемым на машине без установленного pymysql."""
    try:
        import pymysql
    except ImportError:
        sys.exit("Нужен python3-pymysql: apt install python3-pymysql")
    return pymysql


# Файл FreePBX -> (таблица realtime, значение type= для отбора секций)
SOURCES = [
    ("pjsip.endpoint.conf", "ps_endpoints", "endpoint"),
    ("pjsip.aor.conf", "ps_aors", "aor"),
    ("pjsip.auth.conf", "ps_auths", "auth"),
    ("pjsip.identify.conf", "ps_endpoint_id_ips", "identify"),
]

# Регистрации на транки провайдеров НЕ переносятся в общую БД.
#
# ps_registrations — таблица без признака узла: положив туда транк, вы
# заставите регистрироваться на него все площадки сразу одним аккаунтом.
# Регистрации у оператора расходуются впустую, а входящий вызов приходит
# на случайный узел вместо того, чей это номер.
#
# У каждой площадки транк свой и описывается локально —
# scripts/setup-local-trunk.sh, см. docs/11-local-trunks.md.
REGISTRATION_SOURCE = ("pjsip.registration.conf", "ps_registrations", "registration")

# Опции, которые могут повторяться и склеиваются в одну строку через запятую.
MULTI_VALUE = {"allow", "disallow", "match", "aors", "auth", "outbound_auth", "contact"}

# Никогда не переносим: это не колонки, а служебные директивы конфига.
SKIP_KEYS = {"type"}

SECTION_RE = re.compile(r"^\[([^\]]+)\]\s*(?:\(([^)]*)\))?\s*$")


def log(msg, quiet=False):
    if not quiet:
        print(msg)


def warn(msg):
    print(f"[!] {msg}", file=sys.stderr)


def parse_pjsip_conf(path):
    """Разбирает pjsip-конфиг в {секция: {ключ: значение}} с раскрытием шаблонов.

    Понимает синтаксис Asterisk:
        [tpl](!)        — определение шаблона
        [name](tpl)     — наследование от шаблона
        key = value     — опция (повторы склеиваются для MULTI_VALUE)
    """
    templates = {}
    sections = {}
    order = []
    current = None
    inherits = {}

    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith((";", "#")):
                continue

            m = SECTION_RE.match(line)
            if m:
                name, tpl = m.group(1), m.group(2)
                if tpl is not None and tpl.strip() == "!":
                    current = name
                    templates[name] = {}
                    continue
                current = name
                sections.setdefault(name, {})
                if name not in order:
                    order.append(name)
                if tpl:
                    inherits[name] = [t.strip() for t in tpl.split(",") if t.strip()]
                continue

            if current is None or "=" not in line:
                continue

            key, _, value = line.partition("=")
            key = key.strip().lower()
            value = value.strip()

            target = templates[current] if current in templates else sections.setdefault(current, {})
            if key in MULTI_VALUE and key in target and target[key]:
                target[key] = f"{target[key]},{value}"
            else:
                target[key] = value

    # Раскрываем наследование от шаблонов.
    #
    # Обычные опции секция переопределяет. А вот накопительные (allow, match,
    # aors...) в Asterisk НЕ переопределяют, а добавляются к унаследованным:
    # [base](!) с allow=ulaw,alaw плюс allow=g722 в секции — это три кодека,
    # а не один. Простое обновление словаря давало бы телефону только g722.
    for name, tpls in inherits.items():
        merged = {}
        for t in tpls:
            for k, v in templates.get(t, {}).items():
                if k in MULTI_VALUE and merged.get(k):
                    merged[k] = f"{merged[k]},{v}"
                else:
                    merged[k] = v
        for k, v in sections.get(name, {}).items():
            if k in MULTI_VALUE and merged.get(k):
                merged[k] = f"{merged[k]},{v}"
            else:
                merged[k] = v
        sections[name] = merged

    return sections, order


def table_columns(cur, dbname, table):
    cur.execute(
        "SELECT column_name FROM information_schema.columns "
        "WHERE table_schema = %s AND table_name = %s",
        (dbname, table),
    )
    return {r[0].lower() for r in cur.fetchall()}


def sync_table(cur, dbname, table, wanted, apply_changes, quiet, unknown_seen):
    """Приводит содержимое realtime-таблицы к набору wanted = {id: {col: val}}."""
    cols = table_columns(cur, dbname, table)
    if not cols:
        warn(f"Таблицы {dbname}.{table} нет — пропускаю. "
             f"Схема realtime не создана? См. docs/06-troubleshooting.md")
        return 0, 0, 0

    filtered = {}
    for sid, opts in wanted.items():
        row = {}
        for k, v in opts.items():
            if k in SKIP_KEYS:
                continue
            if k in cols:
                row[k] = v
            else:
                unknown_seen.setdefault(table, set()).add(k)
        filtered[sid] = row

    cur.execute(f"SELECT id FROM `{table}`")
    existing = {r[0] for r in cur.fetchall()}

    to_insert = set(filtered) - existing
    to_update = set(filtered) & existing
    to_delete = existing - set(filtered)

    if not apply_changes:
        return len(to_insert), len(to_update), len(to_delete)

    for sid in sorted(to_insert | to_update):
        row = filtered[sid]
        row_cols = ["id"] + sorted(row)
        values = [sid] + [row[c] for c in sorted(row)]
        placeholders = ", ".join(["%s"] * len(row_cols))
        collist = ", ".join(f"`{c}`" for c in row_cols)
        updates = ", ".join(f"`{c}` = VALUES(`{c}`)" for c in row_cols if c != "id")
        sql = f"INSERT INTO `{table}` ({collist}) VALUES ({placeholders})"
        if updates:
            sql += f" ON DUPLICATE KEY UPDATE {updates}"
        cur.execute(sql, values)

    for sid in sorted(to_delete):
        cur.execute(f"DELETE FROM `{table}` WHERE id = %s", (sid,))

    return len(to_insert), len(to_update), len(to_delete)


def read_cluster_env(path="/etc/asterisk-cluster/cluster.env"):
    env = {}
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                env[k.strip()] = v.strip().strip('"')
    return env


def main():
    env = read_cluster_env()

    ap = argparse.ArgumentParser(
        description="Выгрузка конфигурации FreePBX в realtime-таблицы ps_*")
    ap.add_argument("--apply", action="store_true",
                    help="применить изменения (без флага — только показать план)")
    ap.add_argument("--quiet", action="store_true", help="меньше вывода")
    ap.add_argument("--asterisk-dir", default="/etc/asterisk")
    ap.add_argument("--db-name", default=env.get("DB_NAME", "asterisk"))
    ap.add_argument("--db-user", default=env.get("RT_USER", "asterisk_rt"))
    ap.add_argument("--db-pass", default=env.get("RT_PASS", ""))
    ap.add_argument("--db-host", default="127.0.0.1")
    ap.add_argument("--context", default="from-site",
                    help="контекст, который прописывается endpoint'ам для "
                         "secondary-узлов (там работает кластерная маршрутизация)")
    ap.add_argument("--keep-context", action="store_true",
                    help="не переписывать context, оставить как у FreePBX")
    ap.add_argument("--include-registrations", action="store_true",
                    help="перенести и регистрации на транки. По умолчанию "
                         "выключено: транки у площадок свои, а таблица общая "
                         "(см. docs/11-local-trunks.md)")
    args = ap.parse_args()

    sources = list(SOURCES)
    if args.include_registrations:
        sources.append(REGISTRATION_SOURCE)
        warn("Регистрации транков переносятся в общую БД: все узлы будут "
             "регистрироваться одним аккаунтом. Убедитесь, что это осознанно.")

    if not args.db_pass:
        sys.exit("Не задан пароль БД: --db-pass или RT_PASS в /etc/asterisk-cluster/cluster.env")

    collected = {}
    for filename, table, wanted_type in sources:
        path = os.path.join(args.asterisk_dir, filename)
        custom = os.path.join(args.asterisk_dir, filename.replace(".conf", "_custom.conf"))

        sections = {}
        for p in (path, custom):
            if not os.path.exists(p):
                continue
            parsed, _order = parse_pjsip_conf(p)
            sections.update(parsed)

        if not sections:
            log(f"    {filename}: файла нет или он пуст", args.quiet)
            collected[table] = {}
            continue

        picked = {
            name: opts for name, opts in sections.items()
            if opts.get("type", "").lower() == wanted_type
        }

        # Межузловые транки генерируются локально на каждом узле
        # (make-node-trunks.sh) и в общую БД попадать не должны — иначе узел
        # получит транк «сам на себя».
        picked = {n: o for n, o in picked.items() if not n.startswith("node-")}

        if table == "ps_endpoints" and not args.keep_context:
            for opts in picked.values():
                opts["context"] = args.context

        collected[table] = picked
        log(f"    {filename}: секций типа {wanted_type} — {len(picked)}", args.quiet)

    conn = _pymysql().connect(
        host=args.db_host, user=args.db_user, password=args.db_pass,
        database=args.db_name, charset="utf8mb4", autocommit=False,
    )

    unknown_seen = {}
    total = [0, 0, 0]
    try:
        with conn.cursor() as cur:
            for _filename, table, _t in sources:
                ins, upd, dele = sync_table(
                    cur, args.db_name, table, collected.get(table, {}),
                    args.apply, args.quiet, unknown_seen)
                total[0] += ins
                total[1] += upd
                total[2] += dele
                log(f"    {table}: +{ins} ~{upd} -{dele}", args.quiet)
        if args.apply:
            conn.commit()
        else:
            conn.rollback()
    finally:
        conn.close()

    for table, keys in sorted(unknown_seen.items()):
        warn(f"{table}: опции без колонки в схеме, пропущены — {', '.join(sorted(keys))}")

    verb = "применено" if args.apply else "будет изменено (пробный прогон)"
    log(f"\nИтого {verb}: добавить {total[0]}, обновить {total[1]}, удалить {total[2]}",
        args.quiet)
    if not args.apply:
        log("Ничего не записано. Для применения добавьте --apply", args.quiet)


if __name__ == "__main__":
    main()
