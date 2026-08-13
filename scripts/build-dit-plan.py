#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Собирает план внедрения Asterisk-кластера в двух форматах ДИТ:
   1) годовой план работ (шаблон «План 2023»)
   2) реестр проектов плана автоматизации (шаблон «Приоритет1_открытые»)
"""
import datetime
import shutil
import zipfile
import xml.etree.ElementTree as ET
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter

XLNS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

# кэш вычисленных значений формул: {(лист, координата): число}
CACHE = {}

def serial(d):
    """Дата -> порядковый номер Excel (система 1900)."""
    return (d - datetime.date(1899, 12, 30)).days

def cache(ws_name, coord, value):
    CACHE[(ws_name, coord)] = value

def inject_cached(path):
    """openpyxl пишет формулы без вычисленных значений, из-за чего любой читатель,
    кроме Excel, видит пустые ячейки. LibreOffice в этом окружении не запускается,
    поэтому значения считаются на Python и вписываются в XML рядом с формулами."""
    tmp = path + ".tmp"
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        wb = ET.fromstring(z.read("xl/workbook.xml"))
        rels = {r.get("Id"): r.get("Target")
                for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))}
        sheet_file = {}
        for s in wb.find(f"{{{XLNS}}}sheets"):
            t = rels[s.get(f"{{{RNS}}}id")].lstrip("/")
            sheet_file[s.get("name")] = t if t.startswith("xl/") else "xl/" + t
        blobs = {n: z.read(n) for n in names}

    ET.register_namespace("", XLNS)
    patched = 0
    for name, fn in sheet_file.items():
        wanted = {c: v for (s, c), v in CACHE.items() if s == name}
        if not wanted:
            continue
        root = ET.fromstring(blobs[fn])
        for c in root.iter(f"{{{XLNS}}}c"):
            f = c.find(f"{{{XLNS}}}f")
            if f is None or c.get("r") not in wanted:
                continue
            for old in c.findall(f"{{{XLNS}}}v"):
                c.remove(old)
            v = ET.SubElement(c, f"{{{XLNS}}}v")
            val = wanted[c.get("r")]
            v.text = repr(val) if isinstance(val, float) else str(val)
            c.attrib.pop("t", None)
            patched += 1
        blobs[fn] = ET.tostring(root, xml_declaration=True, encoding="UTF-8")

    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for n in names:
            z.writestr(n, blobs[n])
    shutil.move(tmp, path)
    return patched

import os, sys
# Каталог для результата: аргумент командной строки или docs/plan рядом со скриптом.
OUT = (sys.argv[1] if len(sys.argv) > 1 else
       os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "plan"))
OUT = os.path.join(os.path.abspath(OUT), "")

START = datetime.date(2026, 9, 7)   # понедельник; допущение, вынесено в «Параметры»
WEEKS = 26
RATE = 11515                        # ₽/ч-д — из формулы =11515*M4 в «План 2023.xlsx»

MONTHS = ["январь","февраль","март","апрель","май","июнь","июль",
          "август","сентябрь","октябрь","ноябрь","декабрь"]
MONTHS_CAP = [m.capitalize() for m in MONTHS]

# ── цвета из исходных файлов ────────────────────────────────────────────────
AMBER   = PatternFill("solid", fgColor="FFFFC000")   # гантт годового плана
GREEN   = PatternFill("solid", fgColor="FF92D050")   # статус «норма»
YELLOW  = PatternFill("solid", fgColor="FFFFFF00")   # статус «внимание» / поля для заполнения
YELL_L  = PatternFill("solid", fgColor="FFFFFF99")
RED     = PatternFill("solid", fgColor="FFFF0000")   # статус «тревога»
HEADFIL = PatternFill("solid", fgColor="FFD9D9D9")
GREYFIL = PatternFill("solid", fgColor="FFF2F2F2")

THIN = Side(style="thin", color="BFBFBF")
BOX  = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)

def wk_start(w):  return START + datetime.timedelta(days=7 * (w - 1))
def wk_end(w):    return wk_start(w) + datetime.timedelta(days=4)
def day_off(d):   return (d - START).days

WEEK_STARTS = [wk_start(w) for w in range(1, WEEKS + 1)]

# ── содержание плана ────────────────────────────────────────────────────────
# (номер, название, недели(от,до), ТРЗ ч/д, проблема, результат)
TASKS = [
 ("1", "Подготовка: сеть, серверы, договорённости с операторами", (1,3), 10,
  "Шесть регионов не связаны между собой сетью; у двух площадок нет собственной АТС; "
  "у операторов нет отдельных учётных записей на каждую площадку",
  "VPN между шестью регионами поднят, RTT измерен и зафиксирован, серверы получены, "
  "у каждой площадки свой SIP-пользователь ВАТС",
  [("1.1","Утвердить единый план нумерации, разослать сотрудникам новые номера",(1,1),1,
    "План нумерации утверждён, уведомления разосланы"),
   ("1.2","Организовать site-to-site VPN между шестью регионами",(1,3),2,
    "Сеть между площадками работает"),
   ("1.3","Замерить RTT и потери между всеми парами регионов",(3,3),2,
    "Замеры выполнены; регионы с RTT выше 50 мс исключены из синхронной репликации"),
   ("1.4","Получить IP-адреса Славянска-на-Кубани и локального PBX",(1,1),1,
    "Адреса получены"),
   ("1.5","Заказать серверы: Ставрополь, Москва, резервный мастер, арбитр",(1,3),2,
    "Четыре сервера получены и доступны по сети"),
   ("1.6","Получить у операторов SIP-пользователей ВАТС на каждую площадку",(2,3),2,
    "Учётные записи получены на все шесть площадок")]),

 ("2", "Смена учётных данных и защита периметра", (2,3), 12,
  "Учётные данные телефонии не менялись; журнал безопасности Asterisk не ведётся, "
  "подбор паролей не отслеживается",
  "Пароли 444 абонентов, транков, AMI и базы данных сменены; включён журнал "
  "безопасности и блокировка подбора; восстановление из резервной копии проверено",
  [("2.1","Включить журнал безопасности, fail2ban, ограничить доступ к AMI",(2,2),2,
    "Попытки подбора фиксируются и блокируются"),
   ("2.2","Задать порядок идентификации абонентов и перечень кодеков",(2,2),1,
    "Идентификация по учётной записи, alaw первым кодеком"),
   ("2.3","Сменить пароли 444 абонентов",(2,3),4,"Пароли сменены"),
   ("2.4","Сменить учётные данные транков, AMI и базы данных",(3,3),2,
    "Учётные данные сменены"),
   ("2.5","Пересобрать конфигурации телефонов",(3,3),1,
    "Телефоны работают с новыми паролями"),
   ("2.6","Проверить восстановление из резервной копии на тестовой машине",(3,3),2,
    "Копия развёрнута и проверена")]),

 ("3", "Испытательный стенд", (3,4), 10,
  "Процедуры восстановления кластера ни разу не выполнялись; способ развёртывания "
  "узла клонированием не проверен",
  "Стенд из двух машин прошёл чек-лист приёмки; восстановление кворума и переключение "
  "мастера выполнены руками",
  [("3.1","Развернуть тестовый мастер",(3,3),2,"Тестовый мастер работает"),
   ("3.2","Клонировать машину мастера и расшить клон в самостоятельный узел",(3,3),2,
    "Клон вступил в кластер, конфликтов имён узлов нет"),
   ("3.3","Прогнать чек-лист приёмки",(4,4),3,"Чек-лист пройден"),
   ("3.4","Отработать восстановление кворума и переключение на резервный мастер",(4,4),3,
    "Процедуры выполнены и задокументированы")]),

 ("4", "Перевод ростовской АТС в режим мастера кластера", (5,6), 5,
  "Существующая АТС работает как отдельная станция и не может обслуживать площадки",
  "Ростовская АТС работает мастером кластера без переустановки; номера доступны "
  "площадкам через общую базу",
  [("4.1","Снять резервную копию, перевести таблицы и запустить репликацию",(5,5),2,
    "База работает в режиме кластера, число добавочных сошлось"),
   ("4.2","Выгрузить номера в общую базу и проверить",(5,5),1,
    "Абоненты видны из общей базы"),
   ("4.3","Неделя наблюдения",(6,6),2,"Отклонений не выявлено")]),

 ("5", "Первая площадка — Воронеж", (6,8), 15,
  "Схема не проверена на реальной нагрузке и реальном канале",
  "Воронеж работает узлом кластера: локальная регистрация телефонов, свой выход в "
  "город, переключение на Ростов при отказе площадки",
  [("5.1","Клонировать машину мастера и расшить клон в узел",(6,6),3,"Узел в кластере"),
   ("5.2","Настроить межузловые транки и перенести диалплан",(6,6),2,
    "Вызовы между Ростовом и Воронежем проходят"),
   ("5.3","Подключить локальный транк оператора",(7,7),2,"Свой выход в город работает"),
   ("5.4","Перевести телефоны на узел через провижининг",(7,7),3,
    "Телефоны регистрируются на площадке, резервный сервер — Ростов"),
   ("5.5","Две недели наблюдения под реальной нагрузкой",(7,8),5,
    "Отказ площадки и возврат отработаны, решение о тиражировании принято")]),

 ("6", "Тиражирование на пять площадок", (9,15), 28,
  "Пять регионов обслуживаются разрозненными станциями либо удалённо из Ростова",
  "Все шесть регионов работают узлами одного кластера, кворум нечётный",
  [("6.1","Мясокомбинат — 187 абонентов",(9,9),5,"Узел работает"),
   ("6.2","Арбитр кворума на отдельном хосте",(10,10),2,
    "Кворум сохраняется при чётном числе узлов"),
   ("6.3","Славянск-на-Кубани (Краснодар) — 140 абонентов",(11,11),5,"Узел работает"),
   ("6.4","Нижний Новгород — 164 абонента",(12,12),5,"Узел работает"),
   ("6.5","Ставрополь — 74 абонента, новый узел вместо обслуживания из Ростова",(13,14),6,
    "Узел работает, абоненты переведены с ростовского сервера"),
   ("6.6","Москва — 80 абонентов, новый узел",(15,15),5,
    "Узел работает, абоненты переведены с Ростова и локального PBX")]),

 ("7", "Резервный мастер", (16,16), 4,
  "Управление кластером сосредоточено на одном сервере",
  "Резервный мастер развёрнут, переключение на него и возврат проверены учебно",
  [("7.1","Развернуть резервный мастер",(16,16),2,"Резервный мастер в кластере"),
   ("7.2","Провести учебное переключение и возврат",(16,16),2,
    "Процедура выполнена в согласованное окно")]),

 ("8", "Консолидация семи мелких АТС", (12,20), 21,
  "Семь станций на 156 абонентов дорого поддерживать и невыгодно включать в кластер "
  "отдельными узлами",
  "Абоненты семи станций переведены на региональные узлы, станции выведены из эксплуатации",
  [("8.1","Калуга — 29 абонентов — в Воронеж",(12,13),3,"Станция выведена"),
   ("8.2","ССЗ — 39 абонентов — в Нижний Новгород",(14,15),3,"Станция выведена"),
   ("8.3","Манитек, Семикаракорский, Цимлянский, Приманыческий — 73 абонента — в Ростов",
    (16,18),10,"Станции выведены"),
   ("8.4","Локальный PBX — 15 абонентов — в Москву",(19,20),5,"Станция выведена")]),

 ("9", "Перевод абонентов на единый план нумерации", (6,26), 25,
  "Двенадцать станций используют пересекающиеся номера, единый план невозможен без "
  "разведения конфликтов",
  "Все абоненты переведены на пятизначную нумерацию, переадресации со старых номеров сняты",
  [("9.1","Воронеж — 229 абонентов",(6,10),4,"Площадка переведена"),
   ("9.2","Мясокомбинат и Калуга — 216 абонентов",(10,14),4,"Площадки переведены"),
   ("9.3","Славянск-на-Кубани — 136 абонентов",(12,16),3,"Площадка переведена"),
   ("9.4","Нижний Новгород и ССЗ — 161 абонент",(14,18),3,"Площадки переведены"),
   ("9.5","Ростов и его мелкие площадки — 352 абонента",(16,20),6,"Площадки переведены"),
   ("9.6","Ставрополь — 74 абонента",(18,22),2,"Площадка переведена"),
   ("9.7","Москва — 80 абонентов",(20,24),2,"Площадка переведена"),
   ("9.8","Снять переадресации со старых номеров",(24,26),1,"Переадресации сняты")]),
]

RISKS = {
 "1": "RTT выше 50 мс до региона — регион не включается в синхронную репликацию, "
      "получает автономную АТС с транком. Отсутствие IP у Славянска-на-Кубани и "
      "локального PBX блокирует недели 11 и 15. Оператор может не дать отдельных "
      "пользователей ВАТС — тогда площадка работает через мастер.",
 "4": "Требуется окно на перезапуск базы: новые вызовы не устанавливаются около минуты.",
 "5": "Контрольная точка: при проблемах на Воронеже тиражирование не начинается, "
      "пока они не закрыты. Пауза заложена в план.",
 "6": "Узлы перезапускаются по одному, работы по площадкам не совмещаются. "
      "Регион 5 в исходных данных назван «Москва, СПб, Новосибирск» — при реальном "
      "размещении в Новосибирске регион исключается из синхронной репликации.",
 "9": "Организационный поток: новые площадки не заводятся до разведения конфликтов "
      "нумерации. Переходный период не менее месяца, старый номер остаётся рабочим.",
}


def month_spans():
    """[(подпись месяца, первый индекс недели, последний индекс недели)] — 0-based."""
    spans, cur, first = [], None, 0
    for i, d in enumerate(WEEK_STARTS):
        key = (d.year, d.month)
        if cur is None:
            cur, first = key, i
        elif key != cur:
            spans.append((f"{MONTHS_CAP[cur[1]-1]} {cur[0]}", first, i - 1))
            cur, first = key, i
    spans.append((f"{MONTHS_CAP[cur[1]-1]} {cur[0]}", first, len(WEEK_STARTS) - 1))
    return spans


def add_params_sheet(wb, kind):
    ws = wb.create_sheet("Параметры и допущения", 0)
    ws.column_dimensions["A"].width = 34
    ws.column_dimensions["B"].width = 22
    ws.column_dimensions["C"].width = 96
    ws["A1"] = "Отказоустойчивый кластер телефонии на шесть регионов"
    ws["A1"].font = Font(name="Arial", sz=14, b=True)
    ws["A2"] = ("Параметры расчёта. Все прочие листы считают от этих значений — "
                "меняйте здесь, а не в самом плане.")
    ws["A2"].font = Font(name="Arial", sz=10, i=True)

    rows = [
        ("Показатель", "Значение", "Откуда взято"),
        ("Дата начала работ", START,
         "ДОПУЩЕНИЕ. Понедельник. Отсчёт идёт от старта работ, то есть от стадии «проект открыт». "
         "Стадии 0–4 воронки плана автоматизации (постановка задачи, оценка, согласование карточки, "
         "ВЕ, приказа) в эти 26 недель не входят и идут до них."),
        ("Длительность, недель", WEEKS, "План внедрения, docs/12-rollout-schedule.md"),
        ("Дата завершения работ", wk_end(WEEKS), "Дата начала + 26 недель, последний рабочий день"),
        ("Трудозатраты, ч-д", 130,
         "26 недель × 5 рабочих дней. План предполагает одного инженера на полной занятости."),
        ("Внутренняя ставка, ₽/ч-д", RATE,
         "Из формулы =11515*M4 в файле «План работ ДИТ 2023.xlsx», колонка «Плановая "
         "себестоимость внутренних затрат»."),
        ("Плановая себестоимость внутренних затрат, ₽ без НДС", None,
         "Трудозатраты × ставка, рассчитывается формулой"),
        ("Плановая себестоимость внешних затрат, ₽ без НДС", 0,
         "Всё программное обеспечение бесплатное: MariaDB Galera, Asterisk, FreePBX, "
         "OSS PBX End Point Manager. Оборудование (4 сервера) проходит закупкой, "
         "в себестоимость работ не входит — как и во всех строках исходного плана ДИТ."),
        ("Абонентов в периметре", 1255, "Аудит 12 станций, docs/plan/numbering-plan.csv"),
        ("Станций сейчас", 12, "Там же"),
        ("Узлов кластера после внедрения", 8, "7 региональных узлов + резервный мастер"),
        ("Голосов в кворуме", 9, "8 узлов + арбитр без данных"),
        ("Новогодние каникулы", "неделя 18",
         "ВНИМАНИЕ. При старте 07.09.2026 неделя 18 приходится на 04–08.01.2027, то есть "
         "на нерабочие дни. Сроки в плане календарные и этого не учитывают. Либо сдвиньте "
         "дату начала, либо считайте план 27-недельным: этапы 8 и 9 (консолидация и "
         "перенумерация) в эту неделю не ведутся."),
    ]
    r = 4
    for a, b, c in rows:
        ws.cell(r, 1, a); ws.cell(r, 2, b); ws.cell(r, 3, c)
        for col in (1, 2, 3):
            cc = ws.cell(r, col)
            cc.font = Font(name="Arial", sz=10, b=(r == 4))
            cc.alignment = Alignment(wrap_text=True, vertical="top")
            cc.border = BOX
            if r == 4:
                cc.fill = HEADFIL
        r += 1
    ws["B5"].number_format = "DD.MM.YYYY"
    ws["B7"].number_format = "DD.MM.YYYY"
    ws["B10"] = "=B8*B9"
    cache(ws.title, "B10", 130 * RATE)
    ws["B10"].number_format = "#,##0"
    ws["B11"].number_format = "#,##0"
    ws.row_dimensions[4].height = 18

    ws["A17"] = "Что нужно заполнить вручную"
    ws["A17"].font = Font(name="Arial", sz=11, b=True)
    manual = [
        ("Заказчик", "Руководитель, от которого идёт задача. Формат «И. Фамилия»."),
        ("Исполнитель", "Инженер проекта и ответственные за стадии. Формат «И. Фамилия»."),
        ("Номер приказа / внутреннего проекта", "Присваивается при открытии проекта."),
        ("IP-адреса Славянска-на-Кубани и локального PBX",
         "В исходных данных аудита отсутствуют, запрашиваются в первую неделю."),
    ]
    r = 18
    for a, c in manual:
        ws.cell(r, 1, a).fill = YELLOW
        ws.cell(r, 1).font = Font(name="Arial", sz=10)
        ws.cell(r, 1).border = BOX
        ws.cell(r, 3, c).font = Font(name="Arial", sz=10)
        ws.cell(r, 3).alignment = Alignment(wrap_text=True, vertical="top")
        r += 1
    ws["A24"] = "Жёлтой заливкой отмечены ячейки, которые заполняются вручную."
    ws["A24"].font = Font(name="Arial", sz=9, i=True)
    return ws


# ══════════════════ ФАЙЛ 1: годовой план работ ══════════════════════════════
def build_annual():
    wb = Workbook()
    wb.remove(wb.active)
    add_params_sheet(wb, "annual")
    ws = wb.create_sheet("План работ")

    heads = ["№","Название задачи","Категория активности","Программа","Заказчик",
             "Плановые сроки начала","Плановые сроки завершения",
             "Фактические/прогнозные сроки завершения","Проблема","Результат",
             "Исполнитель","Статус","ТРЗ, ч/д",
             "Плановая себестоимость внутренних затрат (ТРЗ), руб. без НДС",
             "Плановая себестоимость внешних затрат, руб. без НДС"]
    widths = [6.7,44,17,16.6,12.7,12.4,14.6,14.3,42,42,17.1,14,8.5,16.3,15.6]
    for i, (h, w) in enumerate(zip(heads, widths), start=1):
        ws.column_dimensions[get_column_letter(i)].width = w
        c = ws.cell(2, i, h)
        c.font = Font(name="Calibri", sz=12, b=True)
        c.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
        c.fill = HEADFIL
        c.border = BOX

    G0 = 16  # первая колонка гантта — P
    for i, d in enumerate(WEEK_STARTS):
        col = G0 + i
        ws.column_dimensions[get_column_letter(col)].width = 6.6
        c = ws.cell(2, col, f"{d.day:02d}-{(d + datetime.timedelta(days=6)).day:02d}")
        c.font = Font(name="Calibri", sz=10, b=True)
        c.alignment = Alignment(horizontal="center")
        c.fill = HEADFIL
        c.border = BOX
    for label, a, b in month_spans():
        c = ws.cell(1, G0 + a, label)
        c.font = Font(name="Calibri", sz=11, b=True)
        c.alignment = Alignment(horizontal="center")
        if b > a:
            ws.merge_cells(start_row=1, start_column=G0 + a, end_row=1, end_column=G0 + b)

    ws.cell(1, 2, "Отказоустойчивый кластер телефонии на шесть регионов "
                  "(Ростов, Воронеж, Краснодар, Нижний Новгород, Москва, Ставрополь)")
    ws.cell(1, 2).font = Font(name="Calibri", sz=12, b=True)

    r = 3
    first_data = r
    for num, name, wks, trz, problem, result, subs in TASKS:
        ws.cell(r, 1, num)
        ws.cell(r, 2, name)
        ws.cell(r, 3, "развитие")
        ws.cell(r, 4, "Инфраструктура")
        ws.cell(r, 5, None)                       # Заказчик — заполнить
        ws.cell(r, 6, f"=Параметры!$B$5+{day_off(wk_start(wks[0]))}")
        ws.cell(r, 7, f"=Параметры!$B$5+{day_off(wk_end(wks[1]))}")
        ws.cell(r, 8, f"=G{r}")
        cache(ws.title, f"F{r}", serial(wk_start(wks[0])))
        cache(ws.title, f"G{r}", serial(wk_end(wks[1])))
        cache(ws.title, f"H{r}", serial(wk_end(wks[1])))
        ws.cell(r, 9, problem)
        ws.cell(r, 10, result)
        ws.cell(r, 11, None)                      # Исполнитель — заполнить
        ws.cell(r, 12, "планируется")
        ws.cell(r, 13, trz)
        ws.cell(r, 14, f"=Параметры!$B$9*M{r}")
        cache(ws.title, f"N{r}", trz * RATE)
        ws.cell(r, 15, 0)
        for col in (5, 11):
            ws.cell(r, col).fill = YELLOW
        for col in range(1, 16):
            c = ws.cell(r, col)
            c.font = Font(name="Calibri", sz=11, b=True)
            c.alignment = Alignment(wrap_text=True, vertical="top")
            c.border = BOX
        for w in range(wks[0], wks[1] + 1):
            c = ws.cell(r, G0 + w - 1); c.fill = AMBER; c.border = BOX
        ws.cell(r, 6).number_format = "DD.MM.YYYY"
        ws.cell(r, 7).number_format = "DD.MM.YYYY"
        ws.cell(r, 8).number_format = "DD.MM.YYYY"
        ws.cell(r, 14).number_format = "#,##0"
        ws.cell(r, 15).number_format = "#,##0"
        r += 1

        for snum, sname, swks, strz, sres in subs:
            ws.cell(r, 1, snum)
            ws.cell(r, 2, sname)
            ws.cell(r, 6, f"=Параметры!$B$5+{day_off(wk_start(swks[0]))}")
            ws.cell(r, 7, f"=Параметры!$B$5+{day_off(wk_end(swks[1]))}")
            cache(ws.title, f"F{r}", serial(wk_start(swks[0])))
            cache(ws.title, f"G{r}", serial(wk_end(swks[1])))
            ws.cell(r, 10, sres)
            ws.cell(r, 11, None)
            ws.cell(r, 12, "планируется")
            ws.cell(r, 13, strz)
            ws.cell(r, 11).fill = YELLOW
            for col in range(1, 16):
                c = ws.cell(r, col)
                c.font = Font(name="Calibri", sz=11)
                c.alignment = Alignment(wrap_text=True, vertical="top")
                c.border = BOX
                if col in (1, 2):
                    c.fill = GREYFIL
            ws.cell(r, 2).alignment = Alignment(wrap_text=True, vertical="top", indent=2)
            for w in range(swks[0], swks[1] + 1):
                c = ws.cell(r, G0 + w - 1); c.fill = AMBER; c.border = BOX
            ws.cell(r, 6).number_format = "DD.MM.YYYY"
            ws.cell(r, 7).number_format = "DD.MM.YYYY"
            r += 1

    # итог
    task_rows = []
    rr = first_data
    for num, name, wks, trz, p, res, subs in TASKS:
        task_rows.append(rr)
        rr += 1 + len(subs)
    ws.cell(r, 2, "ИТОГО по проекту")
    ws.cell(r, 13, "=" + "+".join(f"M{x}" for x in task_rows))
    ws.cell(r, 14, "=" + "+".join(f"N{x}" for x in task_rows))
    ws.cell(r, 15, "=" + "+".join(f"O{x}" for x in task_rows))
    tot = sum(t[3] for t in TASKS)
    cache(ws.title, f"M{r}", tot)
    cache(ws.title, f"N{r}", tot * RATE)
    cache(ws.title, f"O{r}", 0)
    for col in range(1, 16):
        c = ws.cell(r, col)
        c.font = Font(name="Calibri", sz=12, b=True)
        c.fill = HEADFIL
        c.border = BOX
    ws.cell(r, 14).number_format = "#,##0"
    ws.cell(r, 15).number_format = "#,##0"

    ws.freeze_panes = "C3"
    ws.row_dimensions[2].height = 46
    ws.sheet_view.zoomScale = 80
    return wb, ws, r


# ══════════════════ ФАЙЛ 2: реестр проектов ═════════════════════════════════
def build_register():
    wb = Workbook()
    wb.remove(wb.active)
    add_params_sheet(wb, "register")
    ws = wb.create_sheet("Приоритет1_открытые")

    heads = {3:"Статус проекта",4:"Срок проекта",5:"Заказчик",6:"Проект",
             7:"Стадии выполнения работ",8:"Исполнитель",9:"ТРЗ, ч/д",10:"Проблемы/Риски"}
    widths = {1:8.7,2:23.9,3:12.0,4:22.0,5:16.6,6:70.7,7:18.3,8:18.4,9:8.9,10:45.4}
    for col, w in widths.items():
        ws.column_dimensions[get_column_letter(col)].width = w
    for col, h in heads.items():
        c = ws.cell(1, col, h)
        c.font = Font(name="Arial", sz=12, b=True)
        c.alignment = Alignment(wrap_text=True, vertical="center", horizontal="center")
        c.fill = HEADFIL
        c.border = BOX

    G0 = 11  # K
    for i, d in enumerate(WEEK_STARTS):
        col = G0 + i
        ws.column_dimensions[get_column_letter(col)].width = 3.9
        c = ws.cell(2, col, f"{d.day:02d}-{(d + datetime.timedelta(days=6)).day:02d}")
        c.font = Font(name="Calibri", sz=9)
        c.alignment = Alignment(horizontal="center")
        c.border = BOX
    for label, a, b in month_spans():
        c = ws.cell(1, G0 + a, label)
        c.font = Font(name="Arial", sz=9, b=True)
        c.alignment = Alignment(horizontal="center")
        if b > a:
            ws.merge_cells(start_row=1, start_column=G0 + a, end_row=1, end_column=G0 + b)

    stage_rows = []
    proj_row = 3
    r = 4
    for num, name, wks, trz, problem, result, subs in TASKS:
        stage_rows.append(r)
        ws.cell(r, 6, f"{num}. {name}")
        ws.cell(r, 7, "планируется")
        ws.cell(r, 8, None)
        ws.cell(r, 8).fill = YELLOW
        ws.cell(r, 9, trz)
        ws.cell(r, 10, RISKS.get(num, ""))
        for col in list(range(3, 11)):
            c = ws.cell(r, col)
            c.font = Font(name="Calibri", sz=12)
            c.alignment = Alignment(wrap_text=True, vertical="top")
            c.border = BOX
        for w in range(wks[0], wks[1] + 1):
            c = ws.cell(r, G0 + w - 1); c.fill = GREEN; c.border = BOX
        r += 1
    last = r - 1

    # строка проекта
    ws.cell(proj_row, 3, "норма")
    ws.cell(proj_row, 4, f"{START.strftime('%d.%m.%y')} - {wk_end(WEEKS).strftime('%d.%m.%y')}")
    ws.cell(proj_row, 5, None)
    ws.cell(proj_row, 6, "Отказоустойчивый кластер телефонии на шесть регионов")
    ws.cell(proj_row, 7, "планируется")
    ws.cell(proj_row, 8, None)
    ws.cell(proj_row, 9, f"=SUM(I4:I{last})")
    cache(ws.title, f"I{proj_row}", sum(t[3] for t in TASKS))
    ws.cell(proj_row, 10,
            "1255 абонентов на 12 станциях сводятся в кластер из 8 узлов. Два узла "
            "(Ставрополь, Москва) создаются заново — своей АТС там нет, абоненты "
            "обслуживаются из Ростова. Контрольная точка после первой площадки: "
            "тиражирование не начинается, пока Воронеж не отработает две недели без замечаний.")
    for col in range(3, 11):
        c = ws.cell(proj_row, col)
        c.font = Font(name="Arial", sz=12, b=True)
        c.fill = GREEN
        c.alignment = Alignment(wrap_text=True, vertical="top")
        c.border = BOX
    for col in (5, 8):
        ws.cell(proj_row, col).fill = YELLOW
    for w in range(1, WEEKS + 1):
        c = ws.cell(proj_row, G0 + w - 1); c.fill = GREEN; c.border = BOX

    # легенда статусов
    lr = last + 3
    ws.cell(lr, 6, "Статусы открытых/закрытых проектов:").font = Font(name="Arial", sz=11, b=True)
    legend = [("норма", GREEN, "отклонений по плановым срокам основных вех/трудозатратам нет"),
              ("внимание", YELL_L, "есть вероятность отклонений по плановым срокам основных "
                                   "вех/трудозатратам, которые могут повлиять на изменение "
                                   "плановых сроков/трудозатрат проекта"),
              ("тревога", RED, "есть отклонения по плановым срокам основных вех/трудозатратам")]
    for i, (nm, fill, desc) in enumerate(legend, start=1):
        c = ws.cell(lr + i, 6, nm); c.fill = fill
        c.font = Font(name="Arial", sz=11, b=True, color="FFFFFF" if nm == "тревога" else "000000")
        c.alignment = Alignment(horizontal="center")
        c.border = BOX
        d = ws.cell(lr + i, 7, desc)
        d.font = Font(name="Arial", sz=10)
        d.alignment = Alignment(wrap_text=True, vertical="top")
        ws.merge_cells(start_row=lr + i, start_column=7, end_row=lr + i, end_column=10)

    ws.freeze_panes = "K3"
    ws.row_dimensions[1].height = 40
    ws.sheet_view.zoomScale = 80
    return wb


if __name__ == "__main__":
    wb1, ws1, total_row = build_annual()
    p1 = OUT + "dit-annual-plan.xlsx"
    wb1.save(p1)
    print("записан:", p1, "| строка итога:", total_row,
          "| значений вписано:", inject_cached(p1))

    wb2 = build_register()
    p2 = OUT + "dit-project-registry.xlsx"
    wb2.save(p2)
    print("записан:", p2, "| значений вписано:", inject_cached(p2))
