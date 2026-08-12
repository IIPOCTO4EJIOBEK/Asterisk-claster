#!/usr/bin/env python3
"""Тесты парсера конфигов PJSIP из scripts/sync-config.py.

Запуск:  python3 tests/test-parser.py
БД не требуется — драйвер в sync-config.py импортируется лениво.
"""

import importlib.util
import os
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

spec = importlib.util.spec_from_file_location(
    "sync_config", os.path.join(ROOT, "scripts", "sync-config.py"))
sc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sc)

FAILED = []


def check(cond, msg):
    if cond:
        print(f"  [ok]   {msg}")
    else:
        print(f"  [FAIL] {msg}")
        FAILED.append(msg)


def parse(text):
    with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False,
                                     encoding="utf-8") as fh:
        fh.write(text)
        path = fh.name
    try:
        return sc.parse_pjsip_conf(path)[0]
    finally:
        os.unlink(path)


print("== наследование шаблонов ==")
s = parse("""
[base-endpoint](!)
type=endpoint
context=from-internal
disallow=all
allow=ulaw
allow=alaw

[564](base-endpoint)
aors=564
auth=564
allow=g722
callerid=Priemnaya <564>
""")
check("base-endpoint" not in s, "шаблон не попадает в результат")
check(s["564"]["context"] == "from-internal", "опция унаследована от шаблона")
check(s["564"]["aors"] == "564", "собственная опция секции сохранена")
# Накопительные опции в Asterisk складываются, а не переопределяются:
# иначе телефон получил бы единственный кодек вместо трёх.
check(s["564"]["allow"] == "ulaw,alaw,g722",
      f"кодеки шаблона и секции сложились (получено: {s['564']['allow']})")
check(s["564"]["callerid"] == "Priemnaya <564>", "значение с угловыми скобками цело")

print("== множественное наследование ==")
s = parse("""
[a](!)
type=endpoint
allow=ulaw
context=ctx-a

[b](!)
context=ctx-b

[700](a,b)
aors=700
""")
check(s["700"]["context"] == "ctx-b", "последний шаблон переопределяет предыдущий")
check(s["700"]["allow"] == "ulaw", "опция из первого шаблона сохранилась")

print("== отбор по типу и отсев межузловых транков ==")
s = parse("""
[564]
type=aor
max_contacts=2

[node-voronezh]
type=aor
contact=sip:10.4.3.6:5060

[trunk-mts]
type=endpoint
context=from-trunk
""")
aors = {n: o for n, o in s.items() if o.get("type") == "aor"}
check(set(aors) == {"564", "node-voronezh"}, "отобраны только секции типа aor")
picked = {n: o for n, o in aors.items() if not n.startswith("node-")}
check(set(picked) == {"564"},
      "межузловые транки не попадают в общую БД (генерируются локально)")

print("== устойчивость к мусору ==")
s = parse("""
; комментарий
# ещё комментарий

[564]
type=endpoint
   context   =   from-internal
строка без знака равенства
=значение без ключа
""")
check(s["564"]["context"] == "from-internal", "пробелы вокруг = обрезаны")
check("type" in s["564"], "секция разобрана несмотря на мусорные строки")

print("== пустой файл ==")
s = parse("")
check(s == {}, "пустой файл даёт пустой результат, а не ошибку")

print()
if FAILED:
    print(f"Провалено проверок: {len(FAILED)}")
    sys.exit(1)
print("Парсер: все проверки пройдены.")
