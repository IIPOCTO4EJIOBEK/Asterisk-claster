#!/usr/bin/env python3
"""
epm-set-site.py — привязывает телефоны OSS Endpoint Manager к их площадкам.

Задача
------
EPM хранит один глобальный адрес сервера (`srvip`), и все телефоны получают
в конфиге именно его. Для кластера нужно другое: телефон должен
регистрироваться на Asterisk СВОЕЙ площадки, а мастер использовать как
резервный регистратор.

Резервный сервер одинаков для всех (это мастер) и добавляется в шаблон —
см. docs/09-epm-integration.md. А вот основной сервер у каждой площадки
свой, и задаётся он здесь.

Как это работает
----------------
EPM поддерживает переопределение настроек на устройство: поле
`endpointman_mac_list.global_settings_override` — PHP-сериализованный массив
с ключами config_location, server_type, srvip, ntp, tz. Тот же механизм
использует интерфейс модуля, когда вы правите настройки конкретного
телефона. Скрипт просто заполняет это поле массово, по правилам.

Правила задаются файлом соответствия площадок:

    # sites.conf — площадка: IP Asterisk : диапазоны добавочных
    rostov:10.1.10.111:1000-1999,10800-10999
    voronezh:10.4.3.6:2000-2999
    slavyansk:10.5.1.4:3000-3999

Использование
-------------
    ./epm-set-site.py --sites sites.conf                # показать план
    ./epm-set-site.py --sites sites.conf --apply        # применить
    ./epm-set-site.py --sites sites.conf --apply --rebuild   # + пересобрать конфиги

После применения телефоны получат новый конфиг при следующей перезагрузке
или по расписанию автопровижининга. Резервный сервер при этом остаётся
прежним — он в шаблоне.
"""

import argparse
import os
import re
import sys


def php_serialize(value):
    """Минимальный сериализатор PHP для строк, чисел и словарей.

    EPM читает это поле через unserialize(), поэтому формат обязан быть
    точным: строки считаются в БАЙТАХ, а не в символах — иначе
    кириллица в значениях сломает разбор на стороне PHP.
    """
    if isinstance(value, str):
        raw = value.encode('utf-8')
        return 's:%d:"%s";' % (len(raw), value)
    if isinstance(value, bool):
        return 'b:%d;' % (1 if value else 0)
    if isinstance(value, int):
        return 'i:%d;' % value
    if value is None:
        return 'N;'
    if isinstance(value, dict):
        parts = []
        for k, v in value.items():
            parts.append(php_serialize(k))
            parts.append(php_serialize(v))
        return 'a:%d:{%s}' % (len(value), ''.join(parts))
    raise TypeError('php_serialize: неподдерживаемый тип %r' % type(value))


def php_unserialize_flat(data):
    """Достаёт пары ключ-значение из простого сериализованного массива.

    Нужен только чтобы показать текущее состояние в плане, поэтому
    поддерживает ровно то, что кладёт EPM: массив строк.
    """
    if not data or not data.startswith('a:'):
        return {}
    items = re.findall(r's:\d+:"(.*?)";', data, re.S)
    return dict(zip(items[0::2], items[1::2]))


def parse_sites(path):
    """Читает файл соответствия площадок."""
    sites = []
    with open(path, encoding='utf-8') as fh:
        for lineno, line in enumerate(fh, 1):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(':')
            if len(parts) != 3:
                sys.exit('%s:%d: ожидается «имя:IP:диапазоны», получено: %s'
                         % (path, lineno, line))
            name, ip, ranges = (p.strip() for p in parts)
            spans = []
            for chunk in ranges.split(','):
                chunk = chunk.strip()
                if not chunk:
                    continue
                if '-' in chunk:
                    lo, hi = chunk.split('-', 1)
                    spans.append((int(lo), int(hi)))
                else:
                    spans.append((int(chunk), int(chunk)))
            if not spans:
                sys.exit('%s:%d: у площадки %s нет диапазонов' % (path, lineno, name))
            sites.append({'name': name, 'ip': ip, 'spans': spans})
    if not sites:
        sys.exit('В %s не описано ни одной площадки' % path)
    return sites


def site_for_ext(sites, ext):
    try:
        n = int(re.sub(r'\D', '', ext or ''))
    except ValueError:
        return None
    for s in sites:
        for lo, hi in s['spans']:
            if lo <= n <= hi:
                return s
    return None


def read_cluster_env(path='/etc/asterisk-cluster/cluster.env'):
    env = {}
    if os.path.exists(path):
        with open(path, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, _, v = line.partition('=')
                    env[k.strip()] = v.strip().strip('"')
    return env


def main():
    env = read_cluster_env()
    ap = argparse.ArgumentParser(
        description='Привязка телефонов EPM к площадкам кластера')
    ap.add_argument('--sites', required=True, help='файл соответствия площадок')
    ap.add_argument('--apply', action='store_true', help='записать изменения')
    ap.add_argument('--rebuild', action='store_true',
                    help='после применения пересобрать конфиги телефонов')
    ap.add_argument('--db-name', default=env.get('DB_NAME', 'asterisk'))
    ap.add_argument('--db-user', default=env.get('RT_USER', 'asterisk_rt'))
    ap.add_argument('--db-pass', default=env.get('RT_PASS', ''))
    ap.add_argument('--db-host', default='127.0.0.1')
    args = ap.parse_args()

    try:
        import pymysql
    except ImportError:
        sys.exit('Нужен python3-pymysql: apt install python3-pymysql')

    if not args.db_pass:
        sys.exit('Не задан пароль БД: --db-pass или RT_PASS в cluster.env')

    sites = parse_sites(args.sites)
    print('Площадок описано: %d' % len(sites))
    for s in sites:
        spans = ', '.join('%d-%d' % (a, b) for a, b in s['spans'])
        print('   %-14s %-15s %s' % (s['name'], s['ip'], spans))

    conn = pymysql.connect(host=args.db_host, user=args.db_user,
                           password=args.db_pass, database=args.db_name,
                           charset='utf8mb4', autocommit=False)

    changed = unchanged = orphan = 0
    plan = []
    try:
        with conn.cursor() as cur:
            # Телефон -> его добавочный: mac_list связан с line_list по mac_id.
            cur.execute("""
                SELECT m.id, m.mac, l.ext, m.global_settings_override
                  FROM endpointman_mac_list m
                  LEFT JOIN endpointman_line_list l
                         ON l.mac_id = m.id AND l.line = 1
            """)
            rows = cur.fetchall()

            for mac_id, mac, ext, override in rows:
                site = site_for_ext(sites, ext)
                if site is None:
                    orphan += 1
                    plan.append(('?', mac, ext, 'нет площадки для добавочного'))
                    continue

                current = php_unserialize_flat(override or '')
                if current.get('srvip') == site['ip']:
                    unchanged += 1
                    continue

                # Сохраняем остальные ключи, если они уже были заданы:
                # config_location и server_type менять нельзя, они общие.
                settings = {
                    'config_location': current.get('config_location', ''),
                    'server_type': current.get('server_type', ''),
                    'srvip': site['ip'],
                    'ntp': current.get('ntp', ''),
                    'tz': current.get('tz', ''),
                }
                blob = php_serialize(settings)
                changed += 1
                plan.append((site['name'], mac, ext,
                             '%s -> %s' % (current.get('srvip', '(глобальный)'), site['ip'])))

                if args.apply:
                    cur.execute(
                        'UPDATE endpointman_mac_list SET global_settings_override = %s '
                        'WHERE id = %s', (blob, mac_id))

        if args.apply:
            conn.commit()
        else:
            conn.rollback()
    finally:
        conn.close()

    print('\nТелефонов всего: %d' % (changed + unchanged + orphan))
    for site, mac, ext, what in plan[:25]:
        print('   %-12s %-13s доб.%-8s %s' % (site, mac, ext or '?', what))
    if len(plan) > 25:
        print('   ... ещё %d' % (len(plan) - 25))

    print('\nИзменить: %d, уже верно: %d, без площадки: %d' % (changed, unchanged, orphan))
    if orphan:
        print('Телефоны без площадки останутся на глобальном srvip.')
        print('Проверьте диапазоны в %s — возможно, план нумерации шире.' % args.sites)

    if not args.apply:
        print('\nНичего не записано. Для применения добавьте --apply')
        return 0

    if args.rebuild:
        print('\nПересобираю конфигурации телефонов...')
        rc = os.system('fwconsole endpoint rebuildall 2>/dev/null'
                       ' || fwconsole reload')
        if rc != 0:
            print('Не удалось пересобрать автоматически. Сделайте вручную:')
            print('   в интерфейсе EPM: Rebuild Configs')
    else:
        print('\nНе забудьте пересобрать конфиги телефонов:')
        print('   fwconsole endpoint rebuildall   (или кнопка Rebuild Configs в EPM)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
