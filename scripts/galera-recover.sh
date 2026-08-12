#!/bin/bash
#
# galera-recover.sh — восстановление кластера после потери кворума.
#
# Когда это нужно: healthcheck сообщил "компонент non-Primary" либо MariaDB
# не стартует после того, как все узлы были выключены одновременно. В таком
# состоянии узлы живы, но отказываются обслуживать запросы, потому что не
# знают, у кого самые свежие данные.
#
#   ./scripts/galera-recover.sh --status     # что происходит (по умолчанию)
#   ./scripts/galera-recover.sh --promote    # объявить ЭТОТ узел первичным
#   ./scripts/galera-recover.sh --bootstrap  # поднять кластер с этого узла
#
# Разница между режимами:
#   --promote   узел работает, но в меньшинстве. Мы говорим ему «считай себя
#               кворумом» (pc.bootstrap). БД не перезапускается, звонки живы.
#   --bootstrap кластер погашен целиком. Узел стартует как первый
#               (galera_new_cluster). Требует, чтобы у ЭТОГО узла был самый
#               свежий seqno — скрипт это проверяет.
#
# ВАЖНО: запускать только на ОДНОМ узле. Если объявить первичными два узла
# одновременно, получится split-brain с расхождением данных.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

MODE=status
ASSUME_YES=0

for arg in "$@"; do
  case $arg in
    --status)    MODE=status ;;
    --promote)   MODE=promote ;;
    --bootstrap) MODE=bootstrap ;;
    --yes|-y)    ASSUME_YES=1 ;;
    -h|--help)   sed -n '2,24p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root

GRASTATE=/var/lib/mysql/grastate.dat

show_local_state() {
  step "Состояние этого узла"
  if systemctl is-active --quiet mariadb; then
    info "mariadb: запущена"
    info "wsrep_cluster_status  = $(wsrep_status wsrep_cluster_status)"
    info "wsrep_cluster_size    = $(cluster_size)"
    info "wsrep_local_state_comment = $(wsrep_status wsrep_local_state_comment)"
    info "wsrep_last_committed  = $(wsrep_status wsrep_last_committed)"
  else
    info "mariadb: остановлена"
    if [ -r "$GRASTATE" ]; then
      info "grastate.dat:"
      sed 's/^/      /' "$GRASTATE"
      SEQ="$(awk -F': *' '/seqno/{print $2}' "$GRASTATE")"
      if [ "$SEQ" = "-1" ]; then
        info "seqno = -1: узел был остановлен некорректно."
        info "Точную позицию можно узнать так:"
        info "  mariadbd --wsrep-recover"
        info "и найти в выводе 'Recovered position: <uuid>:<seqno>'"
      fi
    fi
  fi
}

case "$MODE" in
  status)
    show_local_state
    cat <<'EOF'

Как решать:

1. Узел жив, но пишет non-Primary (связь с частью площадок пропала).
   Сравните wsrep_last_committed на всех доступных узлах и на том, где
   значение НАИБОЛЬШЕЕ, выполните:
       ./scripts/galera-recover.sh --promote

2. Кластер погашен целиком (все mariadb остановлены).
   На каждом узле посмотрите seqno:
       cat /var/lib/mysql/grastate.dat
   либо, если там -1:
       mariadbd --wsrep-recover
   На узле с наибольшим seqno выполните:
       ./scripts/galera-recover.sh --bootstrap
   Остальные узлы после этого запускаются обычным systemctl start mariadb
   и подтянут данные по SST.

3. Кластер из двух узлов регулярно теряет кворум при обрыве связи —
   это не поломка, а свойство схемы. Лечится третьим голосом:
       ./scripts/install-garbd.sh   (на отдельном третьем хосте)

EOF
    ;;

  promote)
    show_local_state
    systemctl is-active --quiet mariadb || die "mariadb не запущена — используйте --bootstrap."
    STATUS="$(wsrep_status wsrep_cluster_status)"
    if [ "$STATUS" = "Primary" ]; then
      log "Узел уже в Primary-компоненте, ничего делать не нужно."
      exit 0
    fi
    warn "Этот узел будет объявлен первичным компонентом кластера."
    warn "Убедитесь, что НИ НА КАКОМ другом узле вы этого не делаете —"
    warn "иначе данные разойдутся (split-brain)."
    if [ "$ASSUME_YES" != 1 ]; then
      read -r -p "Продолжить? [y/N] " a
      case "$a" in y|Y|yes|да|Да) ;; *) die "Отменено." ;; esac
    fi
    mysql_exec "SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';"
    sleep 2
    log "Готово. Состояние: $(wsrep_status wsrep_cluster_status), размер: $(cluster_size)"
    ;;

  bootstrap)
    if systemctl is-active --quiet mariadb; then
      die "mariadb запущена. Для живого узла используйте --promote,
или остановите MariaDB, если действительно хотите пересобрать кластер."
    fi
    show_local_state

    SEQ="-1"
    [ -r "$GRASTATE" ] && SEQ="$(awk -F': *' '/seqno/{print $2}' "$GRASTATE")"
    if [ "$SEQ" = "-1" ]; then
      warn "seqno = -1 — позиция неизвестна. Определяю через --wsrep-recover..."
      REC="$(mariadbd --wsrep-recover 2>&1 | grep -o 'Recovered position: .*' || true)"
      if [ -n "$REC" ]; then
        info "$REC"
        warn "Сверьте это значение с остальными узлами: bootstrap делают на узле"
        warn "с НАИБОЛЬШИМ seqno, иначе более свежие данные будут затёрты."
      fi
    else
      info "Локальный seqno: $SEQ"
    fi

    warn "Кластер будет пересобран с ЭТОГО узла как с первого."
    warn "Все остальные узлы затем получат его данные через SST — их локальные"
    warn "изменения, если они были, потеряются."
    if [ "$ASSUME_YES" != 1 ]; then
      read -r -p "Точно продолжить? [y/N] " a
      case "$a" in y|Y|yes|да|Да) ;; *) die "Отменено." ;; esac
    fi

    # safe_to_bootstrap=1 разрешает Galera стартовать с этого узла.
    if [ -w "$GRASTATE" ]; then
      backup_file "$GRASTATE"
      if grep -q safe_to_bootstrap "$GRASTATE"; then
        sed -i 's/^safe_to_bootstrap:.*/safe_to_bootstrap: 1/' "$GRASTATE"
      else
        echo "safe_to_bootstrap: 1" >>"$GRASTATE"
      fi
      info "safe_to_bootstrap выставлен в 1"
    fi

    galera_new_cluster || die "Не удалось запустить кластер. journalctl -u mariadb -n 100"
    wait_for_mysql 90 || die "MariaDB не поднялась."
    log "Кластер поднят. Размер: $(cluster_size), состояние: $(wsrep_status wsrep_local_state_comment)"
    log "Теперь на остальных узлах: systemctl start mariadb"
    ;;
esac
