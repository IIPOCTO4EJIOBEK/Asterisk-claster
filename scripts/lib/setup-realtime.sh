#!/bin/bash
#
# setup-realtime.sh — общая часть настройки realtime для мастера и secondary.
# Вызывается из install-master.sh и clone-node.sh, отдельно запускать не нужно.
#
#   setup-realtime.sh --node-name= --node-ip= --db-name= --rt-user= --rt-pass=
#                     --local-net= --sip-port= --role=master|secondary
#                     [--master-node-name=]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

ROLE=secondary
MASTER_NODE_NAME=""

for arg in "$@"; do
  case $arg in
    --node-name=*) NODE_NAME="${arg#*=}" ;;
    --node-ip=*)   NODE_IP="${arg#*=}" ;;
    --db-name=*)   DB_NAME="${arg#*=}" ;;
    --rt-user=*)   RT_USER="${arg#*=}" ;;
    --rt-pass=*)   RT_PASS="${arg#*=}" ;;
    --local-net=*) LOCAL_NET="${arg#*=}" ;;
    --sip-port=*)  SIP_PORT="${arg#*=}" ;;
    --role=*)      ROLE="${arg#*=}" ;;
    --master-node-name=*) MASTER_NODE_NAME="${arg#*=}" ;;
    *) die "setup-realtime: неизвестный параметр $arg" ;;
  esac
done

: "${NODE_NAME:?}"; : "${NODE_IP:?}"; : "${DB_NAME:?}"
: "${RT_USER:?}";  : "${RT_PASS:?}"
: "${LOCAL_NET:=10.0.0.0/8}"; : "${SIP_PORT:=5060}"
export NODE_NAME NODE_IP DB_NAME RT_USER RT_PASS LOCAL_NET SIP_PORT MASTER_NODE_NAME

#-----------------------------------------------------------------------------
# ODBC: пакеты и — главное — реальное имя драйвера.
#-----------------------------------------------------------------------------
ensure_pkg unixodbc odbc-mariadb

# В /etc/odbcinst.ini пакет odbc-mariadb регистрируется как "MariaDB Unicode",
# в других сборках — иначе. Черновик жёстко писал "MariaDB", и соединение
# не поднималось. Спрашиваем систему вместо угадывания.
ODBC_DRIVER_NAME="$(odbcinst -q -d 2>/dev/null | tr -d '[]' | grep -i maria | head -1 || true)"
if [ -z "$ODBC_DRIVER_NAME" ]; then
  ODBC_DRIVER_NAME="$(odbcinst -q -d 2>/dev/null | tr -d '[]' | grep -i -E 'mysql' | head -1 || true)"
fi
[ -n "$ODBC_DRIVER_NAME" ] || die "Не найден ODBC-драйвер MariaDB/MySQL. Проверьте: odbcinst -q -d"
export ODBC_DRIVER_NAME
info "ODBC-драйвер: '$ODBC_DRIVER_NAME'"

render_tpl "$REPO_ROOT/config/odbc/odbc.ini.tpl" /etc/odbc.ini 0644

#-----------------------------------------------------------------------------
# Модули Asterisk для ODBC. Имя пакета отличается между Debian и сборками
# Sangoma; в Debian res_odbc лежит внутри asterisk-modules, отдельного
# пакета asterisk-odbc (как в черновике) не существует.
#-----------------------------------------------------------------------------
if [ ! -e /usr/lib/asterisk/modules/res_odbc.so ]; then
  if PKG="$(first_available_pkg asterisk-modules asterisk-odbc)"; then
    ensure_pkg "$PKG"
  else
    die "Не найден пакет с res_odbc.so (пробовал asterisk-modules, asterisk-odbc)."
  fi
fi
[ -e /usr/lib/asterisk/modules/res_odbc.so ] || die "res_odbc.so отсутствует после установки пакетов."

#-----------------------------------------------------------------------------
# Конфигурация Asterisk
#-----------------------------------------------------------------------------
render_tpl "$REPO_ROOT/config/asterisk/res_odbc.conf.tpl" /etc/asterisk/res_odbc.conf 0640
render_tpl "$REPO_ROOT/config/asterisk/func_odbc.conf.tpl" /etc/asterisk/func_odbc.conf 0640

if [ "$ROLE" = "master" ]; then
  render_tpl "$REPO_ROOT/config/asterisk/extconfig_master.conf.tpl" /etc/asterisk/extconfig.conf 0640
  render_tpl "$REPO_ROOT/config/asterisk/sorcery_master.conf.tpl"   /etc/asterisk/sorcery.conf   0640
else
  render_tpl "$REPO_ROOT/config/asterisk/extconfig.conf.tpl" /etc/asterisk/extconfig.conf 0640
  render_tpl "$REPO_ROOT/config/asterisk/sorcery.conf.tpl"   /etc/asterisk/sorcery.conf   0640
fi

render_tpl "$REPO_ROOT/config/asterisk/extensions_cluster.conf.tpl" \
           /etc/asterisk/extensions_cluster.conf 0640

#-----------------------------------------------------------------------------
# systemname — из него res_pjsip заполняет ps_contacts.reg_server, а по нему
# диалплан узнаёт, на какой площадке зарегистрирован абонент. Без этого вся
# межузловая маршрутизация не работает.
#-----------------------------------------------------------------------------
AST_CONF=/etc/asterisk/asterisk.conf
if grep -qE '^\s*systemname\s*=' "$AST_CONF" 2>/dev/null; then
  CURRENT="$(sed -n 's/^\s*systemname\s*=\s*\(.*\)$/\1/p' "$AST_CONF" | head -1 | tr -d ' ')"
  if [ "$CURRENT" != "$NODE_NAME" ]; then
    backup_file "$AST_CONF"
    sed -i "s/^\s*systemname\s*=.*/systemname = ${NODE_NAME}/" "$AST_CONF"
    info "systemname изменён с '$CURRENT' на '$NODE_NAME'"
  else
    info "systemname уже '$NODE_NAME'"
  fi
else
  backup_file "$AST_CONF"
  if grep -q '^\[options\]' "$AST_CONF" 2>/dev/null; then
    sed -i "/^\[options\]/a systemname = ${NODE_NAME}" "$AST_CONF"
  else
    printf '\n[options]\nsystemname = %s\n' "$NODE_NAME" >>"$AST_CONF"
  fi
  info "systemname = $NODE_NAME добавлен в asterisk.conf"
fi

#-----------------------------------------------------------------------------
# Порядок загрузки модулей: res_odbc и res_config_odbc должны подняться
# раньше res_pjsip, иначе realtime-источник ещё не готов к моменту,
# когда PJSIP запрашивает endpoint'ы.
#-----------------------------------------------------------------------------
MODCONF=/etc/asterisk/modules.conf
if [ -f "$MODCONF" ]; then
  ensure_line 'preload => res_odbc.so' "$MODCONF"
  ensure_line 'preload => res_config_odbc.so' "$MODCONF"
fi

#-----------------------------------------------------------------------------
# Подключение файлов кластера в диалплан и PJSIP
#-----------------------------------------------------------------------------
if [ "$ROLE" = "master" ]; then
  # Хук [from-internal-custom]: FreePBX включает этот контекст первым внутри
  # from-internal, поэтому кластерная маршрутизация перехватывает набор до
  # штатной обработки и возвращает управление, если абонент местный.
  render_tpl "$REPO_ROOT/config/asterisk/extensions_master_hook.conf.tpl" \
             /etc/asterisk/extensions_master_hook.conf 0640

  # FreePBX перегенерирует extensions.conf и pjsip.conf при каждом Apply
  # Config, поэтому цепляемся только к *_custom.conf — их FreePBX не трогает.
  ensure_line '#include "extensions_cluster.conf"' /etc/asterisk/extensions_custom.conf
  ensure_line '#include "extensions_master_hook.conf"' /etc/asterisk/extensions_custom.conf
  chown asterisk:asterisk /etc/asterisk/extensions_custom.conf 2>/dev/null || true
else
  render_tpl "$REPO_ROOT/config/asterisk/pjsip_transport.conf.tpl" \
             /etc/asterisk/pjsip_transport.conf 0640

  # На secondary pjsip.conf наш: транспорт + межузловые транки + realtime.
  backup_file /etc/asterisk/pjsip.conf
  cat >/etc/asterisk/pjsip.conf <<'EOF'
; /etc/asterisk/pjsip.conf (secondary-узел)
; Управляется scripts/clone-node.sh. Абоненты и транки живут в realtime (БД),
; здесь только то, что специфично для узла.

#include "pjsip_transport.conf"

; Межузловые транки, генерируются scripts/make-node-trunks.sh.
#include "pjsip_nodes.conf"
EOF
  # Пустая заглушка, чтобы Asterisk стартовал до первого make-node-trunks.sh.
  [ -f /etc/asterisk/pjsip_nodes.conf ] || \
    printf '; Заполняется scripts/make-node-trunks.sh\n' >/etc/asterisk/pjsip_nodes.conf

  MASTER_NODE_NAME="${MASTER_NODE_NAME:-master}"
  export MASTER_NODE_NAME
  render_tpl "$REPO_ROOT/config/asterisk/extensions_secondary.conf.tpl" \
             /etc/asterisk/extensions.conf 0640
  install -d -m 0750 -o asterisk -g asterisk /etc/asterisk/from-master 2>/dev/null || \
    install -d -m 0750 /etc/asterisk/from-master
fi

chown -R asterisk:asterisk /etc/asterisk 2>/dev/null || true
info "Realtime-конфигурация записана (роль: $ROLE)"
