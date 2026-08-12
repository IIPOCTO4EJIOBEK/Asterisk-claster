#!/bin/bash
#
# setup-local-trunk.sh — локальный транк провайдера на площадке.
#
# Зачем. Пока все внешние вызовы идут через мастер, его отказ оставляет все
# площадки без внешней связи, хотя их собственные каналы живы. Операторы
# (Ростелеком, Манго) допускают несколько точек подключения к виртуальной
# АТС — до 10, — поэтому каждая площадка может регистрироваться сама.
#
# ВАЖНО: у каждой площадки должен быть СВОЙ пользователь ВАТС, а не общий
# на всех. Иначе оператор не будет знать, на какую площадку слать входящий
# вызов, и отправит его на любую зарегистрированную.
#
# Запускать НА ПЛОЩАДКЕ от root:
#
#   ./scripts/setup-local-trunk.sh \
#     --trunk-name=mango-voronezh \
#     --host=vpbx.mango-office.ru \
#     --user=<пользователь ВАТС этой площадки> \
#     --pass='<пароль>' \
#     --did=4732XXXXXX
#
# Параметры:
#   --trunk-name=  имя транка: a-z0-9-, попадает в имена секций PJSIP
#   --host=        адрес SIP-сервера оператора
#   --user=        логин SIP-пользователя ВАТС ЭТОЙ площадки
#   --pass=        пароль
#   --did=         внешний номер площадки (для маршрутизации входящих)
#   --context=     контекст входящих (по умолчанию from-trunk-site)
#   --expiry=      время регистрации, сек (по умолчанию 300)
#   --no-reload    не перезагружать PJSIP
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env /etc/asterisk-cluster/cluster.env

TRUNK_CONTEXT=from-trunk-site
TRUNK_EXPIRY=300
RELOAD=1
DID=""

for arg in "$@"; do
  case $arg in
    --trunk-name=*) TRUNK_NAME="${arg#*=}" ;;
    --host=*)       TRUNK_HOST="${arg#*=}" ;;
    --user=*)       TRUNK_USER="${arg#*=}" ;;
    --pass=*)       TRUNK_PASS="${arg#*=}" ;;
    --did=*)        DID="${arg#*=}" ;;
    --context=*)    TRUNK_CONTEXT="${arg#*=}" ;;
    --expiry=*)     TRUNK_EXPIRY="${arg#*=}" ;;
    --no-reload)    RELOAD=0 ;;
    -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
: "${TRUNK_NAME:?--trunk-name обязателен}"
: "${TRUNK_HOST:?--host обязателен}"
: "${TRUNK_USER:?--user обязателен}"
: "${TRUNK_PASS:?--pass обязателен}"
: "${NODE_NAME:?Не удалось определить имя узла. Сначала clone-node.sh либо задайте NODE_NAME.}"

case "$TRUNK_NAME" in
  ''|*[!a-z0-9-]*) die "Имя транка '$TRUNK_NAME' некорректно: разрешены a-z, 0-9, дефис." ;;
esac

export TRUNK_NAME TRUNK_HOST TRUNK_USER TRUNK_PASS TRUNK_CONTEXT TRUNK_EXPIRY NODE_NAME

#-----------------------------------------------------------------------------
step "Конфигурация транка"
#-----------------------------------------------------------------------------
render_tpl "$REPO_ROOT/config/asterisk/pjsip_local_trunk.conf.tpl" \
           /etc/asterisk/pjsip_local_trunk.conf 0640
chown asterisk:asterisk /etc/asterisk/pjsip_local_trunk.conf 2>/dev/null || true

# Подключаем в pjsip.conf узла (на площадке файл наш) либо в pjsip_custom.conf
# (на мастере под FreePBX — его FreePBX не перезаписывает).
if command -v fwconsole >/dev/null 2>&1; then
  ensure_line '#include "pjsip_local_trunk.conf"' /etc/asterisk/pjsip_custom.conf
  chown asterisk:asterisk /etc/asterisk/pjsip_custom.conf 2>/dev/null || true
else
  ensure_line '#include "pjsip_local_trunk.conf"' /etc/asterisk/pjsip.conf
fi

#-----------------------------------------------------------------------------
step "Маршрутизация"
#-----------------------------------------------------------------------------
# Исходящие: диалплан площадки берёт имя транка из глобальной переменной.
GLOBALS=/etc/asterisk/globals_custom.conf
if grep -q '^LOCAL_TRUNK=' "$GLOBALS" 2>/dev/null; then
  backup_file "$GLOBALS"
  sed -i "s/^LOCAL_TRUNK=.*/LOCAL_TRUNK=${TRUNK_NAME}/" "$GLOBALS"
  info "LOCAL_TRUNK обновлён на ${TRUNK_NAME}"
else
  ensure_line "LOCAL_TRUNK=${TRUNK_NAME}" "$GLOBALS"
fi
chown asterisk:asterisk "$GLOBALS" 2>/dev/null || true

# Входящие: если задан DID — направляем его на местный диалплан.
INBOUND=/etc/asterisk/extensions_trunk_local.conf
if [ -n "$DID" ]; then
  backup_file "$INBOUND"
  cat >"$INBOUND" <<EOF
; Входящие с локального транка площадки ${NODE_NAME}.
; Сгенерировано setup-local-trunk.sh $(date -Is).

[${TRUNK_CONTEXT}]
; Внешний номер площадки -> её внутренняя обработка.
; Замените назначение на нужное: конкретный добавочный, IVR или очередь.
exten => ${DID},1,NoOp(Входящий на ${DID}, площадка ${NODE_NAME})
	same => n,Goto(from-trunk,\${EXTEN},1)

; Всё остальное с этого транка — тоже в общую обработку входящих.
exten => _X.,1,NoOp(Входящий \${EXTEN} с транка ${TRUNK_NAME})
	same => n,Goto(from-trunk,\${EXTEN},1)
EOF
  chown asterisk:asterisk "$INBOUND" 2>/dev/null || true
  ensure_line '#include "extensions_trunk_local.conf"' /etc/asterisk/extensions_custom.conf
  info "Входящие на ${DID} направлены в from-trunk"
else
  warn "--did не задан: контекст входящих ${TRUNK_CONTEXT} не создан."
  warn "Входящие вызовы с этого транка обрабатываться не будут."
fi

#-----------------------------------------------------------------------------
step "Применение"
#-----------------------------------------------------------------------------
if [ "$RELOAD" = 1 ] && asterisk_running; then
  asterisk -rx "module reload res_pjsip.so" >/dev/null 2>&1 || true
  asterisk -rx "dialplan reload" >/dev/null 2>&1 || true
  sleep 3
  info "Состояние регистрации:"
  asterisk -rx "pjsip show registrations" 2>/dev/null | sed 's/^/    /' | head -10
else
  info "Перезагрузка пропущена. Примените: asterisk -rx 'module reload res_pjsip.so'"
fi

cat <<EOF

Транк ${TRUNK_NAME} настроен на площадке ${NODE_NAME}.

Проверьте:
  asterisk -rx "pjsip show registrations"     # должно быть Registered
  asterisk -rx "pjsip show aors ${TRUNK_NAME}"

Исходящие вызовы теперь идут через локальный транк, а при его недоступности
диалплан площадки перебрасывает их на мастер (см. extensions_cluster.conf).

Если оператор ограничивает число одновременных подключений, следите за тем,
чтобы у каждой площадки был СВОЙ пользователь ВАТС. Общий аккаунт на все
площадки сделает маршрутизацию входящих непредсказуемой.

EOF
