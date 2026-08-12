#!/usr/bin/env python3
"""
check-numbering.py — поиск конфликтов нумерации перед объединением АТС.

Шаг 0 внедрения: пока один и тот же внутренний номер существует на разных
АТС, объединять нечего. В общей таблице ps_endpoints два абонента с номером
564 — это не «разберёмся потом», а невозможность вставить вторую строку с
тем же первичным ключом.

Скрипт собирает добавочные со всех площадок и показывает:
  - номера, встречающиеся более чем на одной АТС;
  - занятые диапазоны по каждой площадке;
  - свободные диапазоны, куда можно перенести конфликтующих.

Источники данных
----------------
    --dump  площадка=/путь/к/дампу.sql     дамп базы FreePBX (таблица users)
    --csv   площадка=/путь/к/файлу.csv     CSV: номер[,имя] в первых колонках
    --live  площадка=user:pass@host/db     подключение к работающей АТС

Примеры
-------
    ./check-numbering.py \\
        --dump rostov=pbx1-10.1.10.111/sql/asterisk-db.sql \\
        --csv voronezh=voronezh-ext.csv

    ./check-numbering.py --dump rostov=dump.sql --plan 4
"""

import argparse
import csv
import os
import re
import sys
from collections import defaultdict


def extensions_from_dump(path):
    """Достаёт добавочные из дампа FreePBX: таблица users (extension, name)."""
    with open(path, encoding="utf-8", errors="replace") as fh:
        sql = fh.read()

    m = re.search(r"INSERT INTO `users` VALUES ", sql)
    if not m:
        return {}

    # Тело INSERT — до ';' вне строкового литерала.
    j, in_str = m.end(), False
    while j < len(sql):
        c = sql[j]
        if in_str:
            if c == "\\":
                j += 2
                continue
            if c == "'":
                in_str = False
        elif c == "'":
            in_str = True
        elif c == ";":
            break
        j += 1
    body = sql[m.end():j]

    # users: (extension, password, name, ...) — берём 1-ю и 3-ю колонки.
    result = {}
    for row in re.finditer(r"\('([^']*)','[^']*','((?:[^']|\\')*)'", body):
        ext, name = row.group(1), row.group(2)
        if ext.strip():
            result[ext.strip()] = name.strip()
    return result


def extensions_from_csv(path):
    result = {}
    with open(path, encoding="utf-8-sig", errors="replace", newline="") as fh:
        sample = fh.read(4096)
        fh.seek(0)
        try:
            dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
        except csv.Error:
            dialect = csv.excel
        for row in csv.reader(fh, dialect):
            if not row:
                continue
            ext = row[0].strip()
            if not ext or not re.fullmatch(r"\d+", ext):
                continue  # заголовок или мусор
            result[ext] = row[1].strip() if len(row) > 1 else ""
    return result


def extensions_from_live(dsn):
    """dsn: user:pass@host/db"""
    m = re.fullmatch(r"([^:]+):([^@]*)@([^/]+)/(.+)", dsn)
    if not m:
        sys.exit(f"Некорректный DSN: {dsn}. Ожидается user:pass@host/db")
    user, password, host, db = m.groups()
    try:
        import pymysql
    except ImportError:
        sys.exit("Для --live нужен python3-pymysql")
    conn = pymysql.connect(host=host, user=user, password=password,
                           database=db, charset="utf8mb4")
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT extension, name FROM users")
            return {str(e).strip(): (n or "") for e, n in cur.fetchall() if str(e).strip()}
    finally:
        conn.close()


def compress_ranges(numbers):
    """Список чисел -> компактные диапазоны [(lo, hi), ...]."""
    nums = sorted(set(numbers))
    if not nums:
        return []
    ranges, start, prev = [], nums[0], nums[0]
    for n in nums[1:]:
        if n == prev + 1:
            prev = n
            continue
        ranges.append((start, prev))
        start = prev = n
    ranges.append((start, prev))
    return ranges


def fmt_ranges(ranges):
    return ", ".join(f"{a}" if a == b else f"{a}-{b}" for a, b in ranges)


def parse_source(arg, kind):
    if "=" not in arg:
        sys.exit(f"--{kind} требует формат площадка=значение, получено: {arg}")
    site, _, value = arg.partition("=")
    return site.strip(), value.strip()


def main():
    ap = argparse.ArgumentParser(description="Поиск конфликтов нумерации между АТС")
    ap.add_argument("--dump", action="append", default=[], metavar="САЙТ=ФАЙЛ")
    ap.add_argument("--csv", action="append", default=[], metavar="САЙТ=ФАЙЛ")
    ap.add_argument("--live", action="append", default=[], metavar="САЙТ=DSN")
    ap.add_argument("--plan", type=int, metavar="ДЛИНА",
                    help="предложить план нумерации указанной длины "
                         "(например 4 или 5 знаков)")
    args = ap.parse_args()

    sources = ([(s, v, extensions_from_dump) for s, v in
                (parse_source(a, "dump") for a in args.dump)] +
               [(s, v, extensions_from_csv) for s, v in
                (parse_source(a, "csv") for a in args.csv)] +
               [(s, v, extensions_from_live) for s, v in
                (parse_source(a, "live") for a in args.live)])

    if not sources:
        ap.error("не задан ни один источник: --dump, --csv или --live")

    by_site = {}
    for site, value, loader in sources:
        if loader is not extensions_from_live and not os.path.exists(value):
            sys.exit(f"Файл не найден: {value}")
        exts = loader(value)
        if not exts:
            print(f"[!] {site}: добавочных не найдено ({value})", file=sys.stderr)
        by_site[site] = exts

    print("=" * 68)
    print("ДОБАВОЧНЫЕ ПО ПЛОЩАДКАМ")
    print("=" * 68)
    total = 0
    for site, exts in sorted(by_site.items()):
        numeric = [int(e) for e in exts if e.isdigit()]
        total += len(exts)
        print(f"\n  {site}: {len(exts)} шт.")
        if numeric:
            print(f"     длина номера: {sorted({len(str(n)) for n in numeric})}")
            rng = compress_ranges(numeric)
            shown = fmt_ranges(rng[:12])
            print(f"     занято: {shown}" + (f" ... (+{len(rng) - 12} диап.)" if len(rng) > 12 else ""))
    print(f"\n  Всего добавочных: {total}")

    # --- конфликты ---
    owners = defaultdict(list)
    for site, exts in by_site.items():
        for e in exts:
            owners[e].append(site)
    conflicts = {e: s for e, s in owners.items() if len(s) > 1}

    print()
    print("=" * 68)
    print("КОНФЛИКТЫ")
    print("=" * 68)
    if not conflicts:
        print("\n  Пересечений нет — номера уникальны во всех площадках.")
    else:
        print(f"\n  Номеров, встречающихся более чем на одной АТС: {len(conflicts)}\n")
        for ext in sorted(conflicts, key=lambda x: (len(x), x))[:40]:
            sites = conflicts[ext]
            who = "; ".join(f"{s}: {by_site[s][ext] or '—'}" for s in sites)
            print(f"     {ext:<8} {who}")
        if len(conflicts) > 40:
            print(f"     ... и ещё {len(conflicts) - 40}")
        print("\n  Эти номера нельзя перенести в общую базу как есть: первичный")
        print("  ключ ps_endpoints не допускает двух одинаковых значений.")
        print("  Перенумеруйте конфликтующие площадки ДО объединения.")

    # --- свободные диапазоны ---
    if args.plan:
        width = args.plan
        lo, hi = 10 ** (width - 1), 10 ** width - 1
        used = {int(e) for exts in by_site.values() for e in exts
                if e.isdigit() and lo <= int(e) <= hi}
        print()
        print("=" * 68)
        print(f"СВОБОДНЫЕ ДИАПАЗОНЫ ({width}-значные)")
        print("=" * 68)
        free, start = [], None
        for n in range(lo, hi + 2):
            if n <= hi and n not in used:
                if start is None:
                    start = n
            elif start is not None:
                free.append((start, n - 1))
                start = None
        # показываем только крупные блоки — мелкие дырки для переноса бесполезны
        big = [(a, b) for a, b in free if b - a + 1 >= 100]
        big.sort(key=lambda r: r[1] - r[0], reverse=True)
        print(f"\n  Занято {len(used)} из {hi - lo + 1} номеров.")
        print(f"  Крупных свободных блоков (от 100 номеров): {len(big)}\n")
        for a, b in big[:15]:
            print(f"     {a}-{b}  ({b - a + 1} номеров)")
        if len(big) > 15:
            print(f"     ... и ещё {len(big) - 15}")
        print("\n  Рекомендация: выделить каждой площадке непрерывный блок и")
        print("  закрепить префикс за площадкой — тогда по номеру видно, где")
        print("  абонент «прописан», и конфликты при росте не возникают.")

    print()
    return 1 if conflicts else 0


if __name__ == "__main__":
    sys.exit(main())
