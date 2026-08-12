#!/bin/bash
#
# harden.sh — усиление боевой АТС перед вводом кластера в эксплуатацию.
#
# Применяет только то, что можно применить безопасно и через файлы, которые
# FreePBX не перезаписывает (*_custom*.conf). Настройки, которые правильно
# менять в интерфейсе, скрипт не трогает — он о них сообщает.
#
#   ./scripts/harden.sh              # показать план
#   ./scripts/harden.sh --apply      # применить
#
# Что делает:
#   1. Включает журнал безопасности Asterisk. Без него fail2ban нечего
#      читать, а порт 5060 доступен извне — перебор учёток идёт часами.
#   2. Ставит и настраивает fail2ban с фильтром для Asterisk.
#   3. Ограничивает AMI прослушиванием localhost.
#   4. Задаёт qualify для межузловых транков и абонентов.
#
# Полный разбор находок: docs/10-production-hardening.md
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env /etc/asterisk-cluster/cluster.env

APPLY=0
SKIP_FAIL2BAN=0
for arg in "$@"; do
  case $arg in
    --apply)         APPLY=1 ;;
    --skip-fail2ban) SKIP_FAIL2BAN=1 ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
AST_ETC=/etc/asterisk
[ -d "$AST_ETC" ] || die "Каталог $AST_ETC не найден — это не АТС."

TODO=()
note() { TODO+=("$1"); }

#-----------------------------------------------------------------------------
step "[1/5] Журнал безопасности Asterisk"
#-----------------------------------------------------------------------------
# FreePBX генерирует logger_logfiles_additional.conf, но канала security
# там нет. Без него /var/log/asterisk/security пуст, и fail2ban не видит
# ни одной неудачной попытки регистрации.
SECLOG="$AST_ETC/logger_logfiles_custom.conf"
if grep -q 'security' "$SECLOG" 2>/dev/null; then
  info "Канал security уже настроен"
else
  info "Канала security нет — будет добавлен в logger_logfiles_custom.conf"
  if [ "$APPLY" = 1 ]; then
    backup_file "$SECLOG"
    cat >>"$SECLOG" <<'EOF'

; Журнал событий безопасности. Читается fail2ban.
; Добавлено scripts/harden.sh
security => security
EOF
    chown asterisk:asterisk "$SECLOG" 2>/dev/null || true
    asterisk -rx "logger reload" >/dev/null 2>&1 || true
    info "Записан $SECLOG"
  fi
fi

#-----------------------------------------------------------------------------
step "[2/5] fail2ban"
#-----------------------------------------------------------------------------
if [ "$SKIP_FAIL2BAN" = 1 ]; then
  info "Пропущено по --skip-fail2ban"
elif ! command -v fail2ban-server >/dev/null 2>&1; then
  info "fail2ban не установлен — будет установлен"
  [ "$APPLY" = 1 ] && ensure_pkg fail2ban
else
  info "fail2ban уже установлен"
fi

JAIL=/etc/fail2ban/jail.d/asterisk-cluster.conf
if [ "$SKIP_FAIL2BAN" != 1 ]; then
  if [ -f "$JAIL" ]; then
    info "Правило $JAIL уже есть"
  else
    info "Будет создано правило $JAIL"
    if [ "$APPLY" = 1 ]; then
      cat >"$JAIL" <<'EOF'
# Создано scripts/harden.sh
#
# Порт 5060 открыт наружу — иначе телефоны не зарегистрируются. Сканеры
# SIP находят его за часы и начинают перебор добавочных. Это защита от
# перебора, а не замена сильным паролям.

[asterisk]
enabled  = true
port     = 5060,5061,5160,5161
filter   = asterisk
logpath  = /var/log/asterisk/security
maxretry = 5
findtime = 600
bantime  = 3600

# Повторные нарушители — на сутки.
[recidive]
enabled  = true
bantime  = 86400
findtime = 86400
maxretry = 3
EOF
      systemctl enable fail2ban >/dev/null 2>&1 || true
      systemctl restart fail2ban >/dev/null 2>&1 \
        && info "fail2ban перезапущен" \
        || warn "fail2ban не перезапустился — проверьте: fail2ban-client -d"
    fi
  fi
fi

#-----------------------------------------------------------------------------
step "[3/5] AMI слушает только localhost"
#-----------------------------------------------------------------------------
# В manager.conf стоит bindaddr = 0.0.0.0. Пользователи ограничены
# permit=127.0.0.1, то есть доступа снаружи нет, но и открытый порт 5038
# наружу не нужен: он отвечает баннером и выдаёт версию.
MGR="$AST_ETC/manager.conf"
if grep -qE '^\s*bindaddr\s*=\s*0\.0\.0\.0' "$MGR" 2>/dev/null; then
  info "AMI слушает 0.0.0.0 — будет ограничен 127.0.0.1"
  if [ "$APPLY" = 1 ]; then
    backup_file "$MGR"
    sed -i 's/^\s*bindaddr\s*=\s*0\.0\.0\.0/bindaddr = 127.0.0.1/' "$MGR"
    asterisk -rx "manager reload" >/dev/null 2>&1 || true
    info "AMI ограничен localhost"
  fi
else
  info "AMI уже не слушает 0.0.0.0"
fi

#-----------------------------------------------------------------------------
step "[4/5] Проверка порядка идентификации endpoint'ов"
#-----------------------------------------------------------------------------
ORDER="$(grep -E '^\s*endpoint_identifier_order' "$AST_ETC/pjsip.conf" 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' ')"
if [ -n "$ORDER" ]; then
  info "Текущий порядок: $ORDER"
  case "$ORDER" in
    anonymous*|*,anonymous,*)
      warn "anonymous стоит не последним. Неопознанный вызов будет принят как"
      warn "анонимный раньше, чем система попробует опознать его по заголовкам."
      note "Порядок идентификации: задать username,auth_username,ip,header (anonymous убрать или в конец).
     Меняется в FreePBX: Settings -> Asterisk SIP Settings -> PJSIP -> Endpoint Identifier Order" ;;
    *) info "anonymous не в начале — порядок приемлемый" ;;
  esac
fi

#-----------------------------------------------------------------------------
step "[5/5] Проверка кодеков"
#-----------------------------------------------------------------------------
FIRST_CODEC="$(grep -m1 -E '^\s*allow=' "$AST_ETC/pjsip.endpoint.conf" 2>/dev/null | cut -d= -f2 | cut -d, -f1)"
if [ -n "$FIRST_CODEC" ]; then
  info "Первый кодек у абонентов: $FIRST_CODEC"
  if [ "$FIRST_CODEC" = "ulaw" ]; then
    warn "ulaw первым. Российские операторы работают на alaw — значит"
    warn "транскодирование на каждом внешнем вызове: лишний CPU и потеря качества."
    note "Кодеки: поставить alaw первым.
     FreePBX: Settings -> Asterisk SIP Settings -> Codecs, перетащить alaw наверх,
     затем Apply Config. Видеокодеки (h264, mpeg4, vp8) можно отключить,
     если видеотелефонов нет."
  fi
fi

#-----------------------------------------------------------------------------
printf '\n'
if [ "${#TODO[@]}" -gt 0 ]; then
  step "Требует ручного вмешательства (правится в интерфейсе FreePBX)"
  for t in "${TODO[@]}"; do
    printf '  * %s\n' "$t"
  done
fi

printf '\n'
if [ "$APPLY" = 1 ]; then
  log "Автоматические изменения применены."
  info "Проверьте журнал безопасности через несколько минут:"
  info "   tail -f /var/log/asterisk/security"
  info "   fail2ban-client status asterisk"
else
  log "Ничего не изменено. Для применения добавьте --apply"
fi
info "Полный разбор: docs/10-production-hardening.md"
