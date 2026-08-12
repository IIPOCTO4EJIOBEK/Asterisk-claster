#!/bin/bash
#
# test-render.sh — тесты рендера шаблонов конфигураций (render_tpl) и
# вспомогательных функций из scripts/lib/common.sh.
#
#   ./tests/test-render.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../scripts/lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0

pass() { printf '  [ok]   %s\n' "$1"; }
fail() { printf '  [FAIL] %s\n' "$1"; FAILED=$((FAILED + 1)); }

# Команда должна завершиться успешно.
expect_ok() {
  local msg="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi
}

# Команда должна завершиться с ошибкой.
expect_fail() {
  local msg="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then fail "$msg"; else pass "$msg"; fi
}

echo "== валидация IP =="
expect_ok   "корректный адрес принят"     is_ipv4 10.4.3.6
expect_fail "10.4.3.999 отвергнут"        is_ipv4 10.4.3.999
expect_fail "неполный адрес отвергнут"    is_ipv4 10.4.3
expect_fail "пустая строка отвергнута"    is_ipv4 ""
expect_fail "адрес с пробелом отвергнут"  is_ipv4 "10.4.3.6 "
expect_fail "буквы отвергнуты"            is_ipv4 "a.b.c.d"

echo "== имя узла =="
# Имя попадает в systemname, wsrep_node_name и в имя PJSIP-транка
# node-<имя>, поэтому набор символов ограничен жёстко.
expect_ok   "корректное имя принято"    require_node_name "voronezh-1"
expect_fail "кириллица отвергнута"      require_node_name "Воронеж"
expect_fail "подчёркивание отвергнуто"  require_node_name "site_1"
expect_fail "пустое имя отвергнуто"     require_node_name ""

echo "== рендер шаблонов =="
export CLUSTER_NAME=asterisk_lab NODE_NAME=site-1 NODE_IP=10.10.10.12 \
       PEERS=10.10.10.11,10.10.10.12 SST_USER=sst_user \
       WSREP_SLAVE_THREADS=4 GCACHE_SIZE=1G
# Пароль со спецсимволами, значимыми для sed: если экранирование сломано,
# в конфиг попадёт мусор либо подстановка не произойдёт вовсе.
export SST_PASS='p@ss/w|th&spec\slash'

GALERA_TPL="$REPO_ROOT/config/galera/60-galera.cnf.tpl"

expect_ok "шаблон Galera отрендерился" \
  render_tpl "$GALERA_TPL" "$WORK/60-galera.cnf"

expect_ok "пароль со спецсимволами подставлен дословно" \
  grep -qF "wsrep_sst_auth=sst_user:${SST_PASS}" "$WORK/60-galera.cnf"

expect_ok "полный список узлов подставлен" \
  grep -q 'gcomm://10.10.10.11,10.10.10.12' "$WORK/60-galera.cnf"

expect_fail "неподставленных плейсхолдеров не осталось" \
  grep -q '{{' "$WORK/60-galera.cnf"

echo "== отказ при незаданной переменной =="
# Молчаливая подстановка пустого значения дала бы нерабочий конфиг,
# который обнаружился бы только при запуске службы.
render_without_gcache() {
  unset GCACHE_SIZE
  render_tpl "$GALERA_TPL" "$WORK/bad.cnf"
}
expect_fail "рендер прерывается, если переменная не задана" render_without_gcache
expect_fail "неполный файл не создаётся" test -f "$WORK/bad.cnf"

echo "== бэкап перед перезаписью =="
printf 'старое содержимое\n' >"$WORK/target.cnf"
expect_ok "перезапись существующего файла" \
  render_tpl "$GALERA_TPL" "$WORK/target.cnf"

BAK="$(find "$WORK" -maxdepth 1 -name 'target.cnf.bak.*' | head -1)"
if [ -n "$BAK" ]; then
  pass "создана резервная копия"
  expect_ok "в копии прежнее содержимое" grep -q 'старое содержимое' "$BAK"
else
  fail "создана резервная копия"
  fail "в копии прежнее содержимое"
fi

echo "== ensure_line идемпотентна =="
INC="$WORK/inc.conf"
ensure_line '#include "pjsip_nodes.conf"' "$INC" >/dev/null
ensure_line '#include "pjsip_nodes.conf"' "$INC" >/dev/null
ensure_line '#include "other.conf"' "$INC" >/dev/null
N_DUP="$(grep -c 'pjsip_nodes.conf' "$INC")"
N_ALL="$(grep -c . "$INC")"
if [ "$N_DUP" = "1" ]; then
  pass "повторный вызов не дублирует строку"
else
  fail "повторный вызов не дублирует строку (найдено: $N_DUP)"
fi
if [ "$N_ALL" = "2" ]; then
  pass "другая строка добавлена"
else
  fail "другая строка добавлена (строк: $N_ALL)"
fi

echo "== cluster_size при недоступной БД =="
# В черновике пустое значение приводило к ошибке арифметического сравнения
# и падению скрипта под set -e.
mysql_local() { return 1; }
V="$(cluster_size)"
if [ "$V" = "0" ]; then
  pass "возвращается 0, а не пустая строка"
else
  fail "возвращается 0, а не пустая строка (получено: '$V')"
fi
if [ "$V" -lt 2 ] 2>/dev/null; then
  pass "результат пригоден для числового сравнения"
else
  fail "результат пригоден для числового сравнения"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "Провалено проверок: $FAILED"
  exit 1
fi
echo "Рендер и утилиты: все проверки пройдены."
