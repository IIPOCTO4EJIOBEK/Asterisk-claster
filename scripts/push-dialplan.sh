#!/bin/bash
#
# push-dialplan.sh — раскладывает диалплан и звуковые файлы с мастера
# по secondary-узлам. Ставится как /usr/local/bin/asterisk-cluster-push-dialplan.
#
# ЗАЧЕМ. Номера и учётки уезжают на площадки через общую БД (realtime), а вот
# диалплан FreePBX рендерит в файлы: IVR, очереди, время работы, Follow Me.
# Реплицировать эти файлы через БД нельзя, поэтому они синхронизируются
# rsync'ом. Черновик упоминал «push-hook» как нечто существующее — здесь он
# реализован.
#
# Запускать на МАСТЕРЕ после каждого Apply Config:
#   ./scripts/push-dialplan.sh --nodes=voronezh=10.4.3.6,slavyansk=10.5.1.4
#
# Можно повесить на хук FreePBX, чтобы срабатывало автоматически:
#   см. docs/05-operations.md, раздел «Автоматическая раскатка диалплана».
#
# Требуется беспарольный ssh с мастера на узлы (ключ root'а мастера в
# authorized_keys узлов) — настраивается один раз при вводе площадки.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo /usr/local)"
if [ -r "$REPO_ROOT/scripts/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$REPO_ROOT/scripts/lib/common.sh"
else
  log() { printf '==> %s\n' "$*"; }
  step() { printf '\n==> %s\n' "$*"; }
  info() { printf '    %s\n' "$*"; }
  warn() { printf '[!] %s\n' "$*" >&2; }
  die() { printf '[x] %s\n' "$*" >&2; exit 1; }
fi

SSH_USER=root
DRY_RUN=0
RELOAD=1
SRC=/etc/asterisk
DEST=/etc/asterisk/from-master

load_cluster_env /etc/asterisk-cluster/cluster.env 2>/dev/null || true

for arg in "$@"; do
  case $arg in
    --nodes=*)   NODES_MAP="${arg#*=}" ;;
    --ssh-user=*) SSH_USER="${arg#*=}" ;;
    --dry-run)   DRY_RUN=1 ;;
    --no-reload) RELOAD=0 ;;
    -h|--help)   sed -n '2,22p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

: "${NODES_MAP:?--nodes обязателен, формат: имя1=ip1,имя2=ip2}"
command -v rsync >/dev/null 2>&1 || die "Нужен rsync: apt install rsync"

# Что именно синхронизируем. Строго список файлов, а не весь /etc/asterisk:
# конфиги, специфичные для узла (pjsip_transport, res_odbc, asterisk.conf,
# pjsip_nodes), затирать на площадках нельзя.
FILES=(
  extensions.conf
  extensions_additional.conf
  extensions_custom.conf
  extensions_override_freepbx.conf
  features.conf
  features_general_additional.conf
  globals_custom.conf
  queues.conf
  queues_additional.conf
  queues_custom.conf
  ivr.conf
  musiconhold.conf
  musiconhold_additional.conf
  voicemail.conf
  ccss.conf
)

step "Подготовка пакета диалплана"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

COPIED=0
for f in "${FILES[@]}"; do
  if [ -r "$SRC/$f" ]; then
    cp -a "$SRC/$f" "$STAGE/"
    COPIED=$((COPIED + 1))
  fi
done
[ "$COPIED" -gt 0 ] || die "В $SRC не найдено ни одного файла диалплана."
info "Файлов в пакете: $COPIED"

# Точка входа для secondary: extensions.conf мастера переименовывается,
# чтобы не конфликтовать с локальным extensions.conf узла, который
# подключает и кластерную логику, и этот файл.
if [ -r "$STAGE/extensions.conf" ]; then
  mv "$STAGE/extensions.conf" "$STAGE/extensions_master.conf"
  # Asterisk разрешает #include относительно каталога конфигурации
  # (/etc/asterisk), а не относительно включающего файла. На площадке пакет
  # лежит в подкаталоге from-master/, поэтому все include внутри нужно
  # переписать на этот подкаталог — иначе Asterisk будет искать файлы в
  # /etc/asterisk и не найдёт их.
  sed -i -E 's|^([[:space:]]*#include[[:space:]]+)"?([^"/[:space:]]+\.conf)"?|\1"from-master/\2"|' \
    "$STAGE/extensions_master.conf"
  info "Пути #include внутри extensions_master.conf переписаны на from-master/"
fi

step "Раскатка по узлам"
IFS=',' read -r -a ENTRIES <<<"$NODES_MAP"
FAILED=()
for entry in "${ENTRIES[@]}"; do
  [ -n "$entry" ] || continue
  case "$entry" in *=*) ;; *) die "Некорректный элемент: '$entry', нужно имя=IP" ;; esac
  name="${entry%%=*}"
  ip="${entry#*=}"

  info "-> $name ($ip)"
  RSYNC_OPTS=(-az --delete --timeout=30 -e "ssh -o BatchMode=yes -o ConnectTimeout=10")
  [ "$DRY_RUN" = 1 ] && RSYNC_OPTS+=(--dry-run -v)

  if rsync "${RSYNC_OPTS[@]}" "$STAGE/" "${SSH_USER}@${ip}:${DEST}/" 2>&1 | sed 's/^/      /'; then
    if [ "$DRY_RUN" = 0 ] && [ "$RELOAD" = 1 ]; then
      if ssh -o BatchMode=yes -o ConnectTimeout=10 "${SSH_USER}@${ip}" \
          "chown -R asterisk:asterisk ${DEST} 2>/dev/null; asterisk -rx 'dialplan reload'" \
          >/dev/null 2>&1; then
        info "   диалплан перезагружен"
      else
        warn "   не удалось перезагрузить диалплан на $name — сделайте вручную:"
        warn "   ssh ${SSH_USER}@${ip} \"asterisk -rx 'dialplan reload'\""
        FAILED+=("$name (reload)")
      fi
    fi
  else
    warn "   rsync на $name не прошёл"
    FAILED+=("$name (rsync)")
  fi
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  printf '\n'
  warn "Проблемные узлы: ${FAILED[*]}"
  warn "Площадка продолжает работать на старом диалплане — это не авария,"
  warn "но изменения там не применились."
  exit 1
fi

log "Диалплан разложен по всем узлам."
