#!/bin/bash
#
# make-node-trunks.sh — генерирует межузловые PJSIP-транки (full mesh).
#
# Без них вызов, попавший на узел А для абонента, зарегистрированного на
# узле Б, доставить некуда. В черновике этого слоя не было вовсе, из-за чего
# пункт чек-листа «звонок между master и slave проходит» был невыполним.
#
# Запускать на КАЖДОМ узле кластера с одним и тем же --peers-map:
#
#   ./scripts/make-node-trunks.sh \
#     --peers-map=rostov=10.10.10.11,voronezh=10.4.3.6,slavyansk=10.5.1.4
#
# Скрипт сам исключает из карты текущий узел (по NODE_NAME из
# /etc/asterisk-cluster/cluster.env либо по --node-name).
#
# Аутентификация между узлами — по IP (type=identify), поверх доверенной
# межплощадочной сети (VPN/L2). Если такой сети нет, включите --with-auth:
# тогда транки будут с паролем, а не только с проверкой адреса.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

OUT=/etc/asterisk/pjsip_nodes.conf
WITH_AUTH=0
TRUNK_PASS=""
RELOAD=1

load_cluster_env /etc/asterisk-cluster/cluster.env

for arg in "$@"; do
  case $arg in
    --peers-map=*) PEERS_MAP="${arg#*=}" ;;
    --node-name=*) NODE_NAME="${arg#*=}" ;;
    --out=*)       OUT="${arg#*=}" ;;
    --with-auth)   WITH_AUTH=1 ;;
    --trunk-pass=*) TRUNK_PASS="${arg#*=}"; WITH_AUTH=1 ;;
    --no-reload)   RELOAD=0 ;;
    -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

: "${PEERS_MAP:?--peers-map обязателен, формат: имя1=ip1,имя2=ip2}"
: "${NODE_NAME:?Не удалось определить имя этого узла. Укажите --node-name=}"
: "${SIP_PORT:=5060}"

require_node_name "$NODE_NAME"

if [ "$WITH_AUTH" = 1 ] && [ -z "$TRUNK_PASS" ]; then
  die "--with-auth требует --trunk-pass=<общий пароль межузловых транков>.
Пароль должен быть одинаковым на всех узлах кластера."
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

{
  echo "; /etc/asterisk/pjsip_nodes.conf"
  echo "; Сгенерировано make-node-trunks.sh $(date -Is) для узла ${NODE_NAME}."
  echo "; Правки вручную будут перезаписаны при следующем запуске."
  echo ";"
  echo "; Каждому соседнему узлу соответствует endpoint node-<имя>."
  echo "; Диалплан (extensions_cluster.conf) набирает PJSIP/<номер>@node-<имя>,"
  echo "; когда ps_contacts говорит, что абонент зарегистрирован на том узле."
  echo
} >"$TMP"

FOUND_SELF=0
COUNT=0
IFS=',' read -r -a ENTRIES <<<"$PEERS_MAP"
for entry in "${ENTRIES[@]}"; do
  [ -n "$entry" ] || continue
  case "$entry" in
    *=*) ;;
    *) die "Некорректный элемент карты узлов: '$entry'. Ожидается имя=IP." ;;
  esac
  pname="${entry%%=*}"
  pip="${entry#*=}"
  require_node_name "$pname"
  require_ipv4 "--peers-map($pname)" "$pip"

  if [ "$pname" = "$NODE_NAME" ]; then
    FOUND_SELF=1
    continue
  fi

  COUNT=$((COUNT + 1))
  {
    echo ";--- узел ${pname} (${pip}) ------------------------------------------"
    echo "[node-${pname}]"
    echo "type=endpoint"
    echo "transport=transport-udp"
    echo "context=from-cluster"
    echo "disallow=all"
    # alaw первым: типовой набор для РФ. g722 оставлен для внутрикластерных
    # плеч — межузловые каналы обычно не узкие, качество лучше.
    echo "allow=alaw,ulaw,g722"
    echo "aors=node-${pname}"
    echo "direct_media=no"
    # Плечо между узлами уже внутри доверенной сети; RTP гоняем через сервер,
    # чтобы не зависеть от NAT между площадками.
    echo "rtp_symmetric=yes"
    echo "force_rport=yes"
    echo "rewrite_contact=yes"
    echo "ice_support=no"
    echo "trust_id_inbound=yes"
    echo "send_pai=yes"
    echo "language=ru"
    if [ "$WITH_AUTH" = 1 ]; then
      echo "outbound_auth=node-${pname}-auth"
      echo "auth=node-${pname}-auth"
    fi
    echo
    echo "[node-${pname}]"
    echo "type=aor"
    echo "contact=sip:${pip}:${SIP_PORT}"
    echo "qualify_frequency=30"
    echo "qualify_timeout=5"
    echo
    echo "[node-${pname}]"
    echo "type=identify"
    echo "endpoint=node-${pname}"
    echo "match=${pip}"
    echo
    if [ "$WITH_AUTH" = 1 ]; then
      echo "[node-${pname}-auth]"
      echo "type=auth"
      echo "auth_type=userpass"
      echo "username=node-${NODE_NAME}"
      echo "password=${TRUNK_PASS}"
      echo
    fi
  } >>"$TMP"
done

[ "$FOUND_SELF" = 1 ] || warn "Текущий узел '$NODE_NAME' не найден в --peers-map.
         Убедитесь, что карта одинакова на всех узлах и содержит все площадки."
[ "$COUNT" -gt 0 ] || die "В карте нет ни одного соседнего узла — генерировать нечего."

backup_file "$OUT"
install -m 0640 "$TMP" "$OUT"
chown asterisk:asterisk "$OUT" 2>/dev/null || true
log "Сгенерировано транков: $COUNT -> $OUT"

# На мастере под FreePBX pjsip.conf перегенерируется, поэтому подключаем
# наш файл через pjsip_custom.conf, который FreePBX не трогает.
if [ -d /etc/asterisk ] && command -v fwconsole >/dev/null 2>&1; then
  ensure_line '#include "pjsip_nodes.conf"' /etc/asterisk/pjsip_custom.conf
  chown asterisk:asterisk /etc/asterisk/pjsip_custom.conf 2>/dev/null || true
fi

if [ "$RELOAD" = 1 ] && asterisk_running; then
  asterisk -rx "module reload res_pjsip.so" >/dev/null 2>&1 || true
  info "res_pjsip перезагружен"
  asterisk -rx "pjsip show endpoints" 2>/dev/null | grep -E '^ *Endpoint: *node-' | sed 's/^/    /' || true
fi
