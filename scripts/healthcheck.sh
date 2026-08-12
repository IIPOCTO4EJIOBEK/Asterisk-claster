#!/bin/bash
#
# healthcheck.sh — состояние узла кластера. Ставится как
# /usr/local/bin/asterisk-cluster-health и запускается таймером раз в минуту.
#
#   asterisk-cluster-health            # человекочитаемо
#   asterisk-cluster-health --quiet    # только проблемы (для systemd/cron)
#   asterisk-cluster-health --prom     # метрики для node_exporter textfile
#
# Коды возврата: 0 — всё в порядке, 1 — есть проблемы, 2 — узел выпал из
# кластера (кворум потерян, требуется вмешательство).
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo /usr/local)"
if [ -r "$REPO_ROOT/scripts/lib/common.sh" ]; then
  # shellcheck source=lib/common.sh
  . "$REPO_ROOT/scripts/lib/common.sh"
else
  # Скрипт копируется в /usr/local/bin отдельно от репозитория — нужен
  # минимальный автономный набор функций.
  log() { printf '==> %s\n' "$*"; }
  info() { printf '    %s\n' "$*"; }
  warn() { printf '[!] %s\n' "$*" >&2; }
  die() { printf '[x] %s\n' "$*" >&2; exit 1; }
  mysql_local() { mysql --protocol=socket -N -B "$@"; }
  wsrep_status() { mysql_local -e "SHOW STATUS LIKE '$1';" 2>/dev/null | awk 'NR==1{print $2}'; }
  cluster_size() { local v; v="$(wsrep_status wsrep_cluster_size)"; case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac; }
  asterisk_running() { asterisk -rx "core show version" >/dev/null 2>&1; }
fi

QUIET=0
PROM=0
PROM_FILE=/var/lib/node_exporter/textfile_collector/asterisk_cluster.prom

for arg in "$@"; do
  case $arg in
    --quiet|-q) QUIET=1 ;;
    --prom)     PROM=1 ;;
    --prom-file=*) PROM_FILE="${arg#*=}"; PROM=1 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
  esac
done

ENVFILE=/etc/asterisk-cluster/cluster.env
NODE_NAME="unknown"; NODE_ROLE="unknown"
if [ -r "$ENVFILE" ]; then
  NODE_NAME="$(awk -F= '/^NODE_NAME=/{print $2}' "$ENVFILE")"
  NODE_ROLE="$(awk -F= '/^NODE_ROLE=/{print $2}' "$ENVFILE")"
fi

PROBLEMS=()
RC=0

say() { [ "$QUIET" = 1 ] || printf '    %s\n' "$*"; }
problem() { PROBLEMS+=("$1"); [ "$RC" -lt 1 ] && RC=1; }
critical() { PROBLEMS+=("$1"); RC=2; }

[ "$QUIET" = 1 ] || printf '=== Узел %s (%s) ===\n' "$NODE_NAME" "$NODE_ROLE"

#--- MariaDB / Galera --------------------------------------------------------
CSIZE=0; CSTATE="n/a"; CREADY="n/a"; CSTATUS="n/a"; FLOWPAUSE=0
if systemctl is-active --quiet mariadb; then
  say "mariadb: активна"
  CSIZE="$(cluster_size)"
  CSTATE="$(wsrep_status wsrep_local_state_comment)"
  CREADY="$(wsrep_status wsrep_ready)"
  CSTATUS="$(wsrep_status wsrep_cluster_status)"
  FLOWPAUSE="$(wsrep_status wsrep_flow_control_paused)"
  say "galera: size=${CSIZE} state=${CSTATE} status=${CSTATUS} ready=${CREADY}"

  [ "$CSTATE" = "Synced" ] || problem "Galera: состояние '${CSTATE}', ожидалось Synced"
  [ "$CREADY" = "ON" ] || critical "Galera: wsrep_ready=${CREADY} — узел не принимает запросы"

  # Non-Primary означает, что узел в меньшинстве и работать не будет,
  # пока кворум не восстановят (см. scripts/galera-recover.sh).
  if [ "$CSTATUS" != "Primary" ]; then
    critical "Galera: компонент '${CSTATUS}' — потерян кворум, нужен galera-recover.sh"
  fi

  # Flow control: узел тормозит весь кластер. Обычно это или медленный диск,
  # или слишком частая запись в ps_contacts.
  if [ -n "$FLOWPAUSE" ] && awk "BEGIN{exit !(${FLOWPAUSE:-0} > 0.1)}" 2>/dev/null; then
    problem "Galera: flow control ${FLOWPAUSE} — узел отстаёт и притормаживает кластер"
  fi
else
  critical "mariadb не запущена"
fi

#--- Asterisk ----------------------------------------------------------------
EP=0; CONTACTS=0; NODETRUNKS_OK=0; NODETRUNKS_TOTAL=0
if systemctl is-active --quiet asterisk && asterisk_running; then
  say "asterisk: активен ($(asterisk -V 2>/dev/null))"

  ODBC="$(asterisk -rx 'odbc show all' 2>/dev/null)"
  if printf '%s' "$ODBC" | grep -qi 'Number of active connections: [1-9]\|Connected.*yes'; then
    say "odbc: соединение с общей БД есть"
  else
    problem "ODBC: нет соединения с общей БД — realtime не работает"
  fi

  EP="$(asterisk -rx 'pjsip show endpoints' 2>/dev/null | grep -c '^ *Endpoint:')"
  CONTACTS="$(asterisk -rx 'pjsip show contacts' 2>/dev/null | grep -c '^ *Contact:')"
  say "pjsip: endpoint'ов ${EP}, контактов ${CONTACTS}"

  # Межузловые транки: Avail означает, что соседняя площадка отвечает
  # на OPTIONS и туда можно маршрутизировать вызовы.
  TRUNK_OUT="$(asterisk -rx 'pjsip show aors' 2>/dev/null | grep 'node-' || true)"
  if [ -n "$TRUNK_OUT" ]; then
    NODETRUNKS_TOTAL="$(printf '%s\n' "$TRUNK_OUT" | grep -c 'node-')"
    NODETRUNKS_OK="$(asterisk -rx 'pjsip show contacts' 2>/dev/null | grep -c 'node-.*Avail' || true)"
    say "межузловые транки: доступно ${NODETRUNKS_OK} из ${NODETRUNKS_TOTAL}"
    if [ "${NODETRUNKS_OK:-0}" -lt "${NODETRUNKS_TOTAL:-0}" ]; then
      problem "Не все площадки отвечают: ${NODETRUNKS_OK}/${NODETRUNKS_TOTAL} межузловых транков доступно"
    fi
  else
    say "межузловые транки: не настроены (make-node-trunks.sh)"
  fi
else
  critical "asterisk не отвечает"
fi

#--- Расхождение времени -----------------------------------------------------
if command -v timedatectl >/dev/null 2>&1; then
  if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
    say "время: синхронизировано"
  else
    problem "Время не синхронизировано по NTP"
  fi
fi

#--- Метрики для Prometheus --------------------------------------------------
if [ "$PROM" = 1 ]; then
  DIR="$(dirname "$PROM_FILE")"
  if install -d -m 0755 "$DIR" 2>/dev/null; then
    TMPF="${PROM_FILE}.$$"
    {
      echo "# HELP asterisk_cluster_galera_size Число узлов в компоненте Galera"
      echo "# TYPE asterisk_cluster_galera_size gauge"
      echo "asterisk_cluster_galera_size{node=\"${NODE_NAME}\"} ${CSIZE}"
      echo "# HELP asterisk_cluster_synced Узел в состоянии Synced"
      echo "# TYPE asterisk_cluster_synced gauge"
      echo "asterisk_cluster_synced{node=\"${NODE_NAME}\"} $([ "$CSTATE" = "Synced" ] && echo 1 || echo 0)"
      echo "# HELP asterisk_cluster_endpoints Число PJSIP endpoint'ов"
      echo "# TYPE asterisk_cluster_endpoints gauge"
      echo "asterisk_cluster_endpoints{node=\"${NODE_NAME}\"} ${EP:-0}"
      echo "# HELP asterisk_cluster_contacts Число зарегистрированных контактов"
      echo "# TYPE asterisk_cluster_contacts gauge"
      echo "asterisk_cluster_contacts{node=\"${NODE_NAME}\"} ${CONTACTS:-0}"
      echo "# HELP asterisk_cluster_node_trunks_available Доступные межузловые транки"
      echo "# TYPE asterisk_cluster_node_trunks_available gauge"
      echo "asterisk_cluster_node_trunks_available{node=\"${NODE_NAME}\"} ${NODETRUNKS_OK:-0}"
      echo "# HELP asterisk_cluster_problems Число выявленных проблем"
      echo "# TYPE asterisk_cluster_problems gauge"
      echo "asterisk_cluster_problems{node=\"${NODE_NAME}\"} ${#PROBLEMS[@]}"
    } >"$TMPF" && mv "$TMPF" "$PROM_FILE"
  fi
fi

#--- Итог --------------------------------------------------------------------
if [ "${#PROBLEMS[@]}" -gt 0 ]; then
  printf '\n' >&2
  for p in "${PROBLEMS[@]}"; do
    printf '[!] %s\n' "$p" >&2
  done
  exit "$RC"
fi

[ "$QUIET" = 1 ] || printf '\nВсё в порядке.\n'
exit 0
