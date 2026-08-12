#!/bin/bash
#
# install-garbd.sh — арбитр Galera (третий голос без хранения данных).
#
# ЗАЧЕМ. Кворум Galera требует, чтобы живая часть кластера содержала больше
# половины узлов. На двух узлах любой обрыв связи оставляет каждую сторону
# с одним голосом из двух — то есть в меньшинстве, и оба узла перестают
# обслуживать запросы. Арбитр даёт третий голос и делает кворум честным.
#
# ГДЕ ЗАПУСКАТЬ. На ОТДЕЛЬНОМ хосте — не на мастере и не на secondary.
# В черновике предлагалось поставить garbd прямо на мастер: тогда падение
# мастера уносит сразу два голоса из трёх, и оставшийся узел всё равно
# оказывается в меньшинстве. Арбитр помогает, только если он умирает
# независимо от узлов БД: подойдёт любая мелкая VM, контейнер или даже
# роутер с Docker — данных он не хранит, ему хватит 128 МБ памяти.
#
#   ./scripts/install-garbd.sh \
#     --cluster-name=asterisk_prod \
#     --nodes=10.10.10.11:4567,10.4.3.6:4567
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env

for arg in "$@"; do
  case $arg in
    --cluster-name=*) CLUSTER_NAME="${arg#*=}" ;;
    --nodes=*)        GARB_NODES="${arg#*=}" ;;
    --options=*)      GARB_OPTIONS="${arg#*=}" ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
: "${CLUSTER_NAME:?--cluster-name обязателен (должен совпадать с wsrep_cluster_name)}"
: "${GARB_NODES:?--nodes обязателен, формат: ip1:4567,ip2:4567}"
: "${GARB_OPTIONS:=}"

# Проверка «а не на узле ли БД мы запускаемся» — самая частая ошибка.
if systemctl list-unit-files 2>/dev/null | grep -q '^mariadb.service' \
   && systemctl is-enabled --quiet mariadb 2>/dev/null; then
  warn "На этом хосте включена MariaDB — похоже, это узел кластера."
  warn "Арбитр на узле БД не добавляет отказоустойчивости: падение хоста"
  warn "уносит и узел, и его голос. Ставьте garbd на отдельную машину."
  read -r -p "Всё равно продолжить? [y/N] " a
  case "$a" in y|Y|yes|да|Да) ;; *) die "Отменено." ;; esac
fi

step "Установка"
ensure_pkg galera-arbitrator-4

step "Конфигурация"
backup_file /etc/default/garb
cat >/etc/default/garb <<EOF
# Сгенерировано install-garbd.sh $(date -Is)
# Адреса узлов кластера, к которым подключается арбитр.
GALERA_NODES="${GARB_NODES}"
# Должно совпадать с wsrep_cluster_name на узлах.
GALERA_GROUP="${CLUSTER_NAME}"
GALERA_OPTIONS="${GARB_OPTIONS}"
LOG_FILE="/var/log/garbd.log"
EOF
chmod 0644 /etc/default/garb

step "Служба"
# В пакетах MariaDB юнит называется garb, а не garbd (в черновике было garbd,
# и systemctl enable падал).
SERVICE=""
for s in garb garbd; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; then
    SERVICE="$s"
    break
  fi
done
[ -n "$SERVICE" ] || die "Не найден юнит garb/garbd. Проверьте: systemctl list-unit-files | grep garb"

systemctl enable --now "$SERVICE"
sleep 2
if systemctl is-active --quiet "$SERVICE"; then
  log "Арбитр ${SERVICE} запущен и подключён к кластеру ${CLUSTER_NAME}"
else
  systemctl status "$SERVICE" --no-pager -l || true
  die "Арбитр не запустился. Проверьте адреса узлов и доступность порта 4567."
fi

cat <<EOF

Проверьте на любом узле БД, что размер кластера увеличился на единицу:
  mysql -e "SHOW STATUS LIKE 'wsrep_cluster_size';"

Было 2 узла — должно стать 3. Теперь обрыв связи между площадками
оставляет большинство на той стороне, где остался арбитр, и эта часть
продолжает работать.

EOF
