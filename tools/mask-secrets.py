#!/usr/bin/env python3
"""
mask-secrets.py — маскирует учётные данные в дампах боевых АТС.

Зачем. Дамп рабочей станции полезен для разработки: по нему видно реальную
схему нумерации, набор опций PJSIP, структуру диалплана. Но вместе с этим он
содержит SIP-пароли абонентов, учётки транков, пароли AMI и БД. Держать их
в репозитории нельзя — скомпрометированная учётка SIP означает звонки за
ваш счёт.

Скрипт заменяет значения секретов на плейсхолдеры, сохраняя структуру
файлов: конфиги остаются валидными, SQL-дамп по-прежнему разворачивается,
имена добавочных и настройки не теряются.

    ./tools/mask-secrets.py pbx1-10.1.10.111            # показать, что найдено
    ./tools/mask-secrets.py pbx1-10.1.10.111 --apply    # заменить

Обрабатываются и tar-архивы: в них лежит копия тех же конфигов, и без
распаковки секреты остались бы в репозитории.

ВАЖНО: маскирование не отменяет ротацию. Если дамп хоть недолго был
доступен, пароли надо считать скомпрометированными и менять.
"""

import argparse
import gzip
import io
import os
import re
import shutil
import sys
import tarfile
import tempfile

MASK = "__MASKED__"

# Значения, распознанные правилами на первом проходе. На втором проходе они
# вычищаются literally по всему дереву.
#
# Это обязательный шаг, а не перестраховка: FreePBX встраивает пароли AMI и
# БД прямо в сгенерированный диалплан (extensions_additional.conf), кладёт
# копии конфигов в *.bak и раздаёт учётки сторонним панелям. Правила «ключ =
# значение» такие места не ловят, а секрет там ровно тот же.
SECRETS_FOUND = set()

# Короткие значения не подметаем: риск задеть постороннюю подстроку выше
# пользы. Такие случаи ловятся правилами первого прохода.
SWEEP_MIN_LEN = 6

# Второй проход заменяет значение по всему дереву, поэтому к нему допускаются
# только значения, похожие на настоящий секрет. Иначе строка-заглушка из
# стокового примера (`password = password`) вычистит слово «password» из
# документации, кода модулей и чужих конфигов.
SWEEP_DENYLIST = {
    'password', 'passwd', 'secret', 'mysecret', 'mypassword', 'yourpassword',
    'changeme', 'change_me', 'letmein', 'example', 'testtest', 'admin',
    'asterisk', 'freepbx', 'unknown', 'default', 'disabled', 'redacted',
    '12345678', '123456789', 'password1', 'notyourpassword',
}

# Значения, не прошедшие фильтр второго прохода. Показываются в отчёте,
# чтобы пропуск был виден, а не молча случился.
SWEEP_SKIPPED = set()


def is_placeholder(value):
    """Значение — переменная шаблона, а не секрет.

    Шаблоны провижининга Endpoint Manager содержат строки вида
    `password = {$secret}`. Замена такой переменной ломает модуль: телефон
    получил бы буквальный плейсхолдер вместо пароля. Такие значения не
    трогаем ни на одном из проходов.
    """
    v = value.strip()
    if re.match(r'^[{<%]', v):                        # {$var}, {{var}}, <...>
        return True
    if re.match(r'^\$\{', v):                         # ${var}
        return True
    if re.fullmatch(r'\$[A-Za-z_][A-Za-z0-9_]*', v):  # $var
        return True
    return False


def sweepable(value):
    """Достаточно ли значение «секретообразно» для сплошной замены."""
    if len(value) < 8:
        return False
    if value.lower() in SWEEP_DENYLIST:
        return False
    # Одно словарное слово из примера — не секрет. Настоящие пароли почти
    # всегда содержат цифры или спецсимволы; на первом проходе такие
    # значения всё равно уже замаскированы по месту.
    if value.isalpha() and len(value) < 12:
        return False
    if is_placeholder(value):
        return False
    return True


def remember(value):
    """Запоминает распознанный секрет для сплошной зачистки на втором проходе."""
    v = value.strip().strip("'\"").strip()
    if len(v) >= SWEEP_MIN_LEN and v != MASK:
        SECRETS_FOUND.add(v)

# --- конфигурационные файлы -------------------------------------------------
# Правила построчные. Комментарии (; и #) не трогаем: там образцы из
# документации, а не рабочие значения, и их маскирование только зашумляет diff.
LINE_RULES = [
    # secret = ..., secret => ...   (manager.conf, iax.conf, sip.conf)
    (re.compile(r'^(\s*secret\s*(?:=>|=)\s*)(\S.*)$', re.I), 'secret'),
    (re.compile(r'^(\s*secret_origional\s*(?:=>|=)\s*)(\S.*)$', re.I), 'secret_origional'),
    # password = ..., password => ...  (res_odbc, pjsip.auth, ari, cdr_*)
    (re.compile(r'^(\s*password\s*(?:=>|=)\s*)(\S.*)$', re.I), 'password'),
    (re.compile(r'^(\s*(?:dbpass|bindpass|authpassword|remotesecret|md5secret|inkeys|outkey)\s*(?:=>|=)\s*)(\S.*)$', re.I), 'прочие пароли'),
    (re.compile(r'^(\s*(?:apikey|api_key|token|secretkey|shared_secret)\s*(?:=>|=)\s*)(\S.*)$', re.I), 'ключи API'),
]

# voicemail.conf: строки вида  1234 => 5678,Имя,почта@example.com
VOICEMAIL_RE = re.compile(r'^(\s*\d+\s*=>\s*)([^,\s]+)(,.*)$')

CONFIG_EXT = {'.conf', '.ini', '.cfg', '.sh', '.php', '.py', '.pl', '.md', '.txt', '.adsi'}

# --- SQL --------------------------------------------------------------------
# Таблицы FreePBX вида (id, keyword, data, flags): маскируем по ключевому слову.
KV_TABLES = {
    'sip':   {'secret', 'secret_origional', 'md5secret', 'remotesecret'},
    'pjsip': {'password', 'secret', 'auth_password'},
    'iax':   {'secret', 'md5secret', 'inkeys', 'outkey'},
}
KV_KEYWORD_IDX, KV_VALUE_IDX = 1, 2

# Таблицы с фиксированным порядком колонок: маскируем по номеру колонки.
POSITIONAL_TABLES = {
    'users': ['password'],
    'userman_users': ['password'],
    'voicemail_admin': [],
}


def split_sql_tuples(values_text):
    """Разбивает список VALUES на кортежи, а кортежи — на поля.

    Возвращает [(начало, конец, [(начало_поля, конец_поля), ...]), ...] —
    позиции в исходной строке. Работаем позициями, а не значениями, чтобы
    при обратной сборке форматирование неизменённых полей осталось нетронутым.
    """
    tuples = []
    i, n = 0, len(values_text)
    while i < n:
        if values_text[i] != '(':
            i += 1
            continue
        start = i
        i += 1
        fields = []
        fstart = i
        in_str = False
        while i < n:
            c = values_text[i]
            if in_str:
                if c == '\\':
                    i += 2
                    continue
                if c == "'":
                    in_str = False
                i += 1
                continue
            if c == "'":
                in_str = True
                i += 1
                continue
            if c == ',':
                fields.append((fstart, i))
                i += 1
                fstart = i
                continue
            if c == ')':
                fields.append((fstart, i))
                i += 1
                break
            i += 1
        tuples.append((start, i, fields))
    return tuples


def table_columns(sql, table):
    m = re.search(r"CREATE TABLE `%s` \((.*?)\n\) ENGINE" % re.escape(table), sql, re.S)
    if not m:
        return []
    return re.findall(r"^\s*`([a-z_0-9]+)`", m.group(1), re.M)


def mask_sql(sql):
    """Маскирует секреты в дампе MySQL. Возвращает (новый_текст, счётчики)."""
    counts = {}
    out = sql

    for table, keywords in KV_TABLES.items():
        pattern = re.compile(r"INSERT INTO `%s` VALUES " % re.escape(table))
        pieces = []
        last = 0
        for m in pattern.finditer(out):
            # тело INSERT — до ближайшего ";\n" вне строкового литерала
            body_start = m.end()
            j, in_str = body_start, False
            while j < len(out):
                c = out[j]
                if in_str:
                    if c == '\\':
                        j += 2
                        continue
                    if c == "'":
                        in_str = False
                elif c == "'":
                    in_str = True
                elif c == ';':
                    break
                j += 1
            body = out[body_start:j]

            edits = []
            for _ts, _te, fields in split_sql_tuples(body):
                if len(fields) <= max(KV_KEYWORD_IDX, KV_VALUE_IDX):
                    continue
                ks, ke = fields[KV_KEYWORD_IDX]
                keyword = body[ks:ke].strip().strip("'").lower()
                if keyword not in keywords:
                    continue
                vs, ve = fields[KV_VALUE_IDX]
                raw = body[vs:ve].strip()
                if raw in ("''", 'NULL', ''):
                    continue
                remember(raw)
                edits.append((vs, ve))

            if edits:
                counts[f"{table} (kv)"] = counts.get(f"{table} (kv)", 0) + len(edits)
                new_body, prev = [], 0
                for vs, ve in edits:
                    new_body.append(body[prev:vs])
                    new_body.append("'%s'" % MASK)
                    prev = ve
                new_body.append(body[prev:])
                body = ''.join(new_body)

            pieces.append(out[last:body_start])
            pieces.append(body)
            last = j
        if pieces:
            pieces.append(out[last:])
            out = ''.join(pieces)

    for table, cols in POSITIONAL_TABLES.items():
        if not cols:
            continue
        columns = table_columns(out, table)
        idxs = [columns.index(c) for c in cols if c in columns]
        if not idxs:
            continue
        m = re.search(r"INSERT INTO `%s` VALUES " % re.escape(table), out)
        if not m:
            continue
        body_start = m.end()
        j, in_str = body_start, False
        while j < len(out):
            c = out[j]
            if in_str:
                if c == '\\':
                    j += 2
                    continue
                if c == "'":
                    in_str = False
            elif c == "'":
                in_str = True
            elif c == ';':
                break
            j += 1
        body = out[body_start:j]

        edits = []
        for _ts, _te, fields in split_sql_tuples(body):
            for idx in idxs:
                if idx >= len(fields):
                    continue
                vs, ve = fields[idx]
                raw = body[vs:ve].strip()
                if raw in ("''", 'NULL', ''):
                    continue
                remember(raw)
                edits.append((vs, ve))
        if edits:
            edits.sort()
            counts[f"{table} ({','.join(cols)})"] = len(edits)
            new_body, prev = [], 0
            for vs, ve in edits:
                new_body.append(body[prev:vs])
                new_body.append("'%s'" % MASK)
                prev = ve
            new_body.append(body[prev:])
            out = out[:body_start] + ''.join(new_body) + out[j:]

    return out, counts


def mask_text(text, filename=''):
    """Маскирует секреты в текстовом конфиге. Возвращает (новый_текст, счёт)."""
    changed = 0
    lines = text.splitlines(keepends=True)
    is_voicemail = filename.endswith('voicemail.conf')

    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith((';', '#')):
            continue

        if is_voicemail:
            m = VOICEMAIL_RE.match(line.rstrip('\n'))
            if m and m.group(2) not in ('', MASK) and not is_placeholder(m.group(2)):
                remember(m.group(2))
                lines[i] = m.group(1) + MASK + m.group(3) + '\n'
                changed += 1
                continue

        for rx, _label in LINE_RULES:
            m = rx.match(line.rstrip('\n'))
            if m:
                value = m.group(2).strip()
                if value and value != MASK and not is_placeholder(value):
                    remember(value)
                    lines[i] = m.group(1) + MASK + '\n'
                    changed += 1
                break

    return ''.join(lines), changed


def process_file(path, apply_changes, report):
    # В /etc/asterisk часть файлов — симлинки, и после распаковки дампа
    # многие из них указывают в никуда. Такие пути просто пропускаем.
    if os.path.islink(path) and not os.path.exists(path):
        return
    if not os.path.isfile(path):
        return

    name = os.path.basename(path)
    ext = os.path.splitext(name)[1].lower()

    if name.endswith('.sql'):
        with open(path, encoding='utf-8', errors='surrogateescape') as fh:
            text = fh.read()
        new, counts = mask_sql(text)
        total = sum(counts.values())
        if total:
            report.append((path, total, counts))
            if apply_changes:
                with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
                    fh.write(new)
        return

    if ext in CONFIG_EXT or ext == '':
        try:
            with open(path, encoding='utf-8', errors='surrogateescape') as fh:
                text = fh.read()
        except (UnicodeDecodeError, IsADirectoryError):
            return
        if '\0' in text[:4096]:
            return
        new, changed = mask_text(text, path)
        if changed:
            report.append((path, changed, {}))
            if apply_changes:
                with open(path, 'w', encoding='utf-8', errors='surrogateescape') as fh:
                    fh.write(new)


def process_tar(path, apply_changes, report):
    """Распаковывает архив, маскирует содержимое, собирает обратно.

    Без этого секреты остались бы в репозитории: архив содержит копию
    тех же конфигов, что и распакованный каталог рядом.
    """
    gz = path.endswith(('.gz', '.tgz'))
    try:
        tf = tarfile.open(path, 'r:gz' if gz else 'r:')
    except (tarfile.TarError, OSError) as e:
        print(f"  [!] {path}: не открывается ({e})", file=sys.stderr)
        return

    members, changed_total = [], 0
    with tf:
        for member in tf.getmembers():
            data = None
            if member.isfile():
                fh = tf.extractfile(member)
                data = fh.read() if fh else b''
                ext = os.path.splitext(member.name)[1].lower()
                if (ext in CONFIG_EXT or ext == '') and b'\0' not in data[:4096]:
                    try:
                        text = data.decode('utf-8', errors='surrogateescape')
                    except UnicodeDecodeError:
                        text = None
                    if text is not None:
                        new, changed = mask_text(text, member.name)
                        if changed:
                            changed_total += changed
                            data = new.encode('utf-8', errors='surrogateescape')
                            member.size = len(data)
            members.append((member, data))

    if not changed_total:
        return

    report.append((path, changed_total, {'внутри архива': changed_total}))
    if not apply_changes:
        return

    tmp = path + '.tmp'
    mode = 'w:gz' if gz else 'w:'
    with tarfile.open(tmp, mode) as out:
        for member, data in members:
            if data is None:
                out.addfile(member)
            else:
                out.addfile(member, io.BytesIO(data))
    shutil.move(tmp, path)


def sweep_bytes(data):
    """Заменяет все известные секреты в произвольном содержимом файла."""
    if not SECRETS_FOUND:
        return data, 0
    try:
        text = data.decode('utf-8', errors='surrogateescape')
    except (UnicodeDecodeError, AttributeError):
        return data, 0
    changed = 0
    for secret in sorted(SECRETS_FOUND, key=len, reverse=True):
        if not sweepable(secret):
            SWEEP_SKIPPED.add(secret)
            continue
        n = text.count(secret)
        if n:
            text = text.replace(secret, MASK)
            changed += n
    if not changed:
        return data, 0
    return text.encode('utf-8', errors='surrogateescape'), changed


def sweep_file(path, apply_changes, report):
    if os.path.islink(path) and not os.path.exists(path):
        return
    if not os.path.isfile(path):
        return
    with open(path, 'rb') as fh:
        data = fh.read()
    if b'\0' in data[:4096]:
        return
    new, changed = sweep_bytes(data)
    if changed:
        report.append((path, changed, {'сплошная зачистка': changed}))
        if apply_changes:
            with open(path, 'wb') as fh:
                fh.write(new)


def sweep_tar(path, apply_changes, report):
    gz = path.endswith(('.gz', '.tgz'))
    try:
        tf = tarfile.open(path, 'r:gz' if gz else 'r:')
    except (tarfile.TarError, OSError):
        return

    members, changed_total = [], 0
    with tf:
        for member in tf.getmembers():
            data = None
            if member.isfile():
                fh = tf.extractfile(member)
                data = fh.read() if fh else b''
                if b'\0' not in data[:4096]:
                    new, changed = sweep_bytes(data)
                    if changed:
                        changed_total += changed
                        data = new
                        member.size = len(data)
            members.append((member, data))

    if not changed_total:
        return
    report.append((path, changed_total, {'сплошная зачистка в архиве': changed_total}))
    if not apply_changes:
        return
    tmp = path + '.tmp'
    with tarfile.open(tmp, 'w:gz' if gz else 'w:') as out:
        for member, data in members:
            if data is None:
                out.addfile(member)
            else:
                out.addfile(member, io.BytesIO(data))
    shutil.move(tmp, path)


def collect_targets(paths):
    targets = []
    for root_path in paths:
        if os.path.isfile(root_path):
            targets.append(root_path)
            continue
        for dirpath, _dirs, files in os.walk(root_path):
            if '.git' in dirpath.split(os.sep):
                continue
            targets.extend(os.path.join(dirpath, f) for f in files)
    return sorted(targets)


def main():
    ap = argparse.ArgumentParser(description='Маскирование секретов в дампах АТС')
    ap.add_argument('paths', nargs='+', help='каталоги или файлы дампа')
    ap.add_argument('--apply', action='store_true',
                    help='записать изменения (без флага — только показать)')
    ap.add_argument('--no-sweep', action='store_true',
                    help='не делать второй проход (только правила)')
    args = ap.parse_args()

    report = []
    targets = collect_targets(args.paths)

    # Проход 1: правила «ключ = значение» и структура SQL.
    for path in targets:
        if path.endswith(('.tar', '.tar.gz', '.tgz')):
            process_tar(path, args.apply, report)
        else:
            process_file(path, args.apply, report)

    # Проход 2: те же значения могли попасть в места, которых правила не
    # знают — в сгенерированный диалплан, в *.bak, в конфиги сторонних
    # панелей. Здесь они вычищаются по совпадению значения.
    if not args.no_sweep and SECRETS_FOUND:
        sweep_set = {v for v in SECRETS_FOUND if sweepable(v)}
        print(f'Сплошная зачистка: значений к поиску — {len(sweep_set)} '
              f'из {len(SECRETS_FOUND)} найденных')
        for path in targets:
            if path.endswith(('.tar', '.tar.gz', '.tgz')):
                sweep_tar(path, args.apply, report)
            else:
                sweep_file(path, args.apply, report)

    if not report:
        print('Секретов по известным правилам не найдено.')
        return 0

    total = 0
    for path, count, detail in report:
        total += count
        print(f'  {count:6d}  {path}')
        for k, v in sorted(detail.items()):
            print(f'          {k}: {v}')

    skipped = {v for v in SECRETS_FOUND if not sweepable(v)}
    if skipped:
        print('\nНе участвовали в сплошной зачистке (похожи на заглушки из')
        print('стоковых примеров, по месту они всё равно замаскированы):')
        for v in sorted(skipped)[:20]:
            print('   ', repr(v))

    verb = 'замаскировано' if args.apply else 'будет замаскировано'
    print(f'\nИтого {verb} значений: {total}')
    if not args.apply:
        print('Ничего не изменено. Для применения добавьте --apply')
    else:
        print('\nМаскирование не отменяет ротацию: если дамп был доступен,')
        print('пароли надо считать скомпрометированными и сменить.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
