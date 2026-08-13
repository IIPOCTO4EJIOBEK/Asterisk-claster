#!/usr/bin/env python3
"""
build-numbering-plan.py — сборка и проверка единого плана нумерации.

Схема, принятая в проекте: пятизначный номер вида

    Р ПП НН
    │  │  └── номер абонента внутри площадки (00-99)
    │  └───── код площадки (00-99)
    └──────── код региона (1-9)

Скрипт читает рабочую таблицу аудита, вычисляет новые номера, находит
конфликты и разрешает их детерминированно, а результат отдаёт в виде
готового плана и файла площадок для кластера.

Какие конфликты бывают и как разрешаются
----------------------------------------
1. Один код площадки у двух АТС. Код остаётся у той, чьи абоненты УЖЕ
   переведены на пятизначные номера (их старый номер совпадает с новым),
   иначе — у той, где абонентов больше. Второй получает ближайший
   свободный код в своём регионе.

2. Два абонента одной площадки получили один номер. Так выходит потому,
   что номер берётся как две последние цифры старого: 458 и 558 дают
   одинаковые «58». Первый по старому номеру остаётся, второму выдаётся
   ближайший свободный номер в том же блоке.

3. Не заполнены регион или код площадки. Такие записи собираются в
   отдельный блок с выделенным кодом площадки, чтобы они не потерялись и
   не заняли чужой диапазон.

Использование
-------------
    ./build-numbering-plan.py --xlsx audit.xlsx --out-dir out/
    ./build-numbering-plan.py --xlsx audit.xlsx --check     # только проверка

На выходе:
    numbering-plan.csv   — итоговый план со старыми и новыми номерами
    sites.conf           — площадки и диапазоны для epm-set-site.py
    numbering-report.txt — что и почему было изменено
"""

import argparse
import collections
import csv
import os
import sys

SHEET = "План"
# Колонки листа: АТС | Номер текущий | Кому | Площадка | Регион | Площадка | Номер
COL = dict(ats=0, old=1, who=2, place=3, region=4, site=5, num=6, note=7)


def cell(v):
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def read_rows(path):
    try:
        import openpyxl
    except ImportError:
        sys.exit("Нужен openpyxl: pip install openpyxl")
    wb = openpyxl.load_workbook(path, data_only=True)
    if SHEET not in wb.sheetnames:
        sys.exit(f"В книге нет листа «{SHEET}». Есть: {wb.sheetnames}")
    out = []
    for r in wb[SHEET].iter_rows(min_row=2, values_only=True):
        if r[COL["old"]] is None and r[COL["num"]] is None:
            continue
        out.append({k: cell(r[i]) for k, i in COL.items()})
    return out


def compose(region, site, num):
    if not (region and site and num):
        return ""
    return f"{region}{site.zfill(2)}{num.zfill(2)}"


def main():
    ap = argparse.ArgumentParser(description="Сборка единого плана нумерации")
    ap.add_argument("--xlsx", required=True)
    ap.add_argument("--out-dir", default="out")
    ap.add_argument("--check", action="store_true",
                    help="только проверить, файлы не создавать")
    ap.add_argument("--spare-site", default="04",
                    help="код площадки для записей без региона (по умолч. 04)")
    args = ap.parse_args()

    recs = read_rows(args.xlsx)
    report = []

    def note(msg):
        report.append(msg)
        print(msg)

    note(f"Записей в таблице: {len(recs)}")

    for x in recs:
        x["site"] = x["site"].zfill(2) if x["site"] else ""
        x["new"] = compose(x["region"], x["site"], x["num"])
        x["changed"] = ""

    # --- какие коды заняты в каждом регионе ---------------------------------
    site_owners = collections.defaultdict(lambda: collections.defaultdict(list))
    for x in recs:
        if x["region"] and x["site"]:
            site_owners[x["region"]][x["site"]].append(x)

    def free_site(region, taken, near=None):
        """Ближайший свободный код площадки.

        near — коды, уже занятые этой же АТС. Новый блок выдаётся рядом с
        ними, чтобы номера одной АТС не расползались по всему региону:
        по диапазону должно быть видно, кому он принадлежит.
        """
        free = [f"{i:02d}" for i in range(100) if f"{i:02d}" not in taken]
        if not free:
            sys.exit(f"В регионе {region} закончились свободные коды площадок")
        if near:
            anchors = [int(c) for c in near]
            return min(free, key=lambda c: min(abs(int(c) - a) for a in anchors))
        return free[0]

    # --- 1. один код площадки у двух АТС ------------------------------------
    note("\n[1] Пересечения кодов площадок между АТС")
    found = 0
    for region, sites in sorted(site_owners.items()):
        for site, rows in sorted(sites.items()):
            owners = sorted({r["ats"] for r in rows})
            if len(owners) < 2:
                continue
            found += 1
            # Кто уже живёт на пятизначных номерах — тот и остаётся.
            def migrated(ats):
                grp = [r for r in rows if r["ats"] == ats]
                return sum(1 for r in grp if r["old"] == r["new"])
            keeper = max(owners, key=lambda a: (migrated(a),
                                                sum(1 for r in rows if r["ats"] == a)))
            note(f"    регион {region}, площадка {site}: {', '.join(o[:22] for o in owners)}")
            note(f"      код остаётся за: {keeper[:30]}"
                 + (" (уже на пятизначных)" if migrated(keeper) else " (больше абонентов)"))
            for other in owners:
                if other == keeper:
                    continue
                taken = set(site_owners[region].keys())
                own = {r["site"] for r in recs
                       if r["ats"] == other and r["region"] == region
                       and r["site"] and r["site"] != site}
                newcode = free_site(region, taken, near=own or None)
                moved = [r for r in rows if r["ats"] == other]
                for r in moved:
                    old_new = r["new"]
                    r["site"] = newcode
                    r["new"] = compose(r["region"], newcode, r["num"])
                    r["changed"] = f"код площадки {site}→{newcode}"
                site_owners[region][newcode].extend(moved)
                note(f"      {other[:30]}: {len(moved)} номеров -> код {newcode} "
                     f"(диапазон {min(r['new'] for r in moved)}-{max(r['new'] for r in moved)})")
    if not found:
        note("    пересечений нет")

    # --- 2. дубли внутри одной площадки -------------------------------------
    note("\n[2] Повторы номеров внутри площадки")
    used = collections.defaultdict(set)
    for x in recs:
        if x["new"]:
            used[(x["region"], x["site"])].add(x["num"].zfill(2))

    seen = {}
    dups = 0
    for x in sorted([r for r in recs if r["new"]], key=lambda r: (r["new"], r["old"])):
        key = x["new"]
        if key not in seen:
            seen[key] = x
            continue
        dups += 1
        block = (x["region"], x["site"])
        for i in range(0, 100):
            cand = f"{i:02d}"
            if cand not in used[block]:
                break
        else:
            sys.exit(f"Блок {block} переполнен")
        used[block].add(cand)
        prev = seen[key]
        note(f"    {key}: «{prev['who'][:24]}» (стар.{prev['old']}) остаётся, "
             f"«{x['who'][:24]}» (стар.{x['old']}) -> {compose(x['region'], x['site'], cand)}")
        x["num"] = cand
        x["new"] = compose(x["region"], x["site"], cand)
        x["changed"] = (x["changed"] + "; " if x["changed"] else "") + "разведён повтор"
        seen[x["new"]] = x
    if not dups:
        note("    повторов нет")

    # --- 3. записи без региона/площадки -------------------------------------
    note("\n[3] Записи без региона или кода площадки")
    orphans = [x for x in recs if not x["new"]]
    if not orphans:
        note("    таких нет")
    else:
        by_ats = collections.defaultdict(list)
        for x in orphans:
            by_ats[x["ats"]].append(x)
        for ats, rows in by_ats.items():
            # Регион берём тот, где у этой АТС больше всего абонентов.
            regions = collections.Counter(r["region"] for r in recs
                                          if r["ats"] == ats and r["region"])
            region = regions.most_common(1)[0][0] if regions else "9"
            taken = set(site_owners[region].keys())
            own = {r["site"] for r in recs
                   if r["ats"] == ats and r["region"] == region and r["site"]}
            code = (args.spare_site if args.spare_site not in taken
                    else free_site(region, taken, near=own or None))
            note(f"    {ats[:30]}: {len(rows)} записей -> регион {region}, площадка {code}")
            blk = (region, code)
            for x in rows:
                n = x["num"].zfill(2) if x["num"] else "00"
                while n in used[blk]:
                    n = f"{(int(n) + 1) % 100:02d}"
                used[blk].add(n)
                x["region"], x["site"], x["num"] = region, code, n
                x["new"] = compose(region, code, n)
                x["changed"] = "назначены регион и площадка"
            site_owners[region][code].extend(rows)

    # --- итоговая проверка ---------------------------------------------------
    note("\n[4] Итоговая проверка")
    final = collections.Counter(x["new"] for x in recs if x["new"])
    left = [n for n, c in final.items() if c > 1]
    empty = [x for x in recs if not x["new"]]
    note(f"    номеров всего: {sum(final.values())}, уникальных: {len(final)}")
    note(f"    оставшихся коллизий: {len(left)}")
    note(f"    записей без номера: {len(empty)}")

    # Новый номер не должен совпасть с чужим действующим — иначе в переходный
    # период два разных человека отзываются на один набор.
    old_map = collections.defaultdict(list)
    for x in recs:
        if x["old"]:
            old_map[x["old"]].append(x)
    cross = 0
    for x in recs:
        if x["new"] and x["new"] in old_map:
            for y in old_map[x["new"]]:
                if y is not x and y["new"] != x["new"]:
                    cross += 1
    note(f"    новый номер совпадает с чужим действующим: {cross}")
    if cross:
        note("    ВНИМАНИЕ: на время переходного периода такие номера")
        note("    развести обязательно, иначе набор неоднозначен.")

    ok = not left and not empty
    if args.check:
        return 0 if ok else 1

    # --- вывод ---------------------------------------------------------------
    os.makedirs(args.out_dir, exist_ok=True)

    plan_path = os.path.join(args.out_dir, "numbering-plan.csv")
    with open(plan_path, "w", encoding="utf-8-sig", newline="") as fh:
        w = csv.writer(fh, delimiter=";")
        w.writerow(["АТС", "Номер текущий", "Номер новый", "Регион",
                    "Площадка", "Кому принадлежит", "Населённый пункт", "Изменение"])
        for x in sorted(recs, key=lambda r: (r["new"] or "z", r["old"])):
            w.writerow([x["ats"], x["old"], x["new"], x["region"],
                        x["site"], x["who"], x["place"], x["changed"]])
    note(f"\nПлан: {plan_path} ({len(recs)} строк)")

    # sites.conf — площадки и их диапазоны для epm-set-site.py
    sites_path = os.path.join(args.out_dir, "sites.conf")
    ranges = collections.defaultdict(list)
    for x in recs:
        if x["new"]:
            ranges[x["ats"]].append(int(x["new"]))
    with open(sites_path, "w", encoding="utf-8") as fh:
        fh.write("# Сгенерировано build-numbering-plan.py\n")
        fh.write("# Формат: имя-площадки:IP её Asterisk:диапазоны добавочных\n")
        fh.write("# IP подставьте вручную — в таблице аудита он указан не для всех.\n\n")
        for ats, nums in sorted(ranges.items()):
            name = ats.split("(")[0].strip().lower()
            name = "".join(c if c.isalnum() else "-" for c in name).strip("-")
            ip = ats.split("(")[1].rstrip(")") if "(" in ats else "IP-НЕ-ЗАДАН"
            nums = sorted(set(nums))
            spans, start, prev = [], nums[0], nums[0]
            for n in nums[1:]:
                if n == prev + 1:
                    prev = n
                    continue
                spans.append((start, prev))
                start = prev = n
            spans.append((start, prev))
            fh.write(f"{name}:{ip}:" + ",".join(
                f"{a}" if a == b else f"{a}-{b}" for a, b in spans) + "\n")
    note(f"Площадки: {sites_path}")

    rep_path = os.path.join(args.out_dir, "numbering-report.txt")
    with open(rep_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(report) + "\n")
    note(f"Отчёт: {rep_path}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
