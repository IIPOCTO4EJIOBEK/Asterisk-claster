#!/bin/bash
#
# preflight.sh — проверки перед установкой узла кластера.
# Ничего не меняет в системе, только диагностирует. Запускать на КАЖДОМ
# сервере до install-master.sh / clone-node.sh.
#
#   ./scripts/preflight.sh --node-ip=10.10.10.12 --peers=10.10.10.11,10.10.10.12
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"
load_cluster_env

FAILS=0
WARNS=0

ok()   { printf '  [ %sok%s ] %s\n' "$C_GRN" "$C_OFF" "$*"; }
bad()  { printf '  [%sFAIL%s] %s\n' "$C_RED" "$C_OFF" "$*"; FAILS=$((FAILS + 1)); }
soso() { printf '  [%swarn%s] %s\n' "$C_YEL" "$C_OFF" "$*"; WARNS=$((WARNS + 1)); }

for arg in "$@"; do
  case $arg in
    --node-ip=*) NODE_IP="${arg#*=}" ;;
    --peers=*)   PEERS="${arg#*=}" ;;
    -h|--help)   sed -n '2,10p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

step "Операционная система"
detect_os
case "$OS_CODENAME" in
  bookworm) ok "Debian 12 (bookworm) — рекомендуемая платформа" ;;
  bullseye) soso "Debian 11 (bullseye): инсталлятор FreePBX 17 рассчитан на bookworm.
         Для мастера возьмите Debian 12, иначе ставьте Asterisk из исходников." ;;
  *) bad "ОС '$OS_ID $OS_CODENAME' не проверялась. Ожидается Debian 12." ;;
esac

step "Права и базовые утилиты"
if [ "$(id -u)" -eq 0 ]; then ok "root"; else bad "нужен root (sudo -i)"; fi
for c in systemctl apt-get awk sed grep; do
  if command -v "$c" >/dev/null 2>&1; then ok "есть $c"; else bad "нет $c"; fi
done
if command -v python3 >/dev/null 2>&1; then
  ok "есть python3 ($(python3 -V 2>&1))"
else
  bad "нет python3 — им работает sync-config.py"
fi

step "Ресурсы"
MEM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_MB" -ge 3800 ]; then ok "RAM ${MEM_MB} MB"
elif [ "$MEM_MB" -ge 1900 ]; then soso "RAM ${MEM_MB} MB — хватит для secondary, для мастера с FreePBX мало (нужно 4 GB)"
else bad "RAM ${MEM_MB} MB — мало даже для secondary"; fi

DISK_GB=$(df -BG --output=avail / | awk 'NR==2 {gsub("G","");print $1}')
if [ "$DISK_GB" -ge 20 ]; then ok "свободно ${DISK_GB} GB на /"
else bad "свободно ${DISK_GB} GB — нужно от 20 GB (SST копирует всю базу)"; fi

CPUS=$(nproc)
if [ "$CPUS" -ge 2 ]; then ok "${CPUS} vCPU"; else soso "${CPUS} vCPU — Galera + Asterisk на одном ядре будут конкурировать"; fi

step "Время"
if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q yes; then
  ok "время синхронизировано по NTP"
else
  soso "NTP не синхронизирован. Расхождение часов ломает и SIP, и сертификацию Galera.
         Лечится: apt install chrony && systemctl enable --now chrony"
fi

step "Сеть"
if [ -n "${NODE_IP:-}" ]; then
  if ip -4 addr show | grep -qw "$NODE_IP"; then
    ok "NODE_IP $NODE_IP найден на интерфейсе"
  else
    bad "NODE_IP $NODE_IP не назначен ни одному интерфейсу этого сервера"
  fi
else
  soso "NODE_IP не задан — пропускаю проверку адреса"
fi

if [ -n "${PEERS:-}" ]; then
  IFS=',' read -r -a PEER_ARR <<<"$PEERS"
  for p in "${PEER_ARR[@]}"; do
    [ -n "$p" ] || continue
    [ "$p" = "${NODE_IP:-}" ] && continue
    if ping -c1 -W2 "$p" >/dev/null 2>&1; then
      RTT=$(ping -c3 -W2 "$p" 2>/dev/null | awk -F'/' '/^rtt|^round-trip/ {print $5}')
      if [ -n "$RTT" ]; then
        # Galera синхронно подтверждает каждую транзакцию — RTT напрямую
        # становится нижней границей времени записи.
        if awk "BEGIN{exit !($RTT > 50)}"; then
          bad "узел $p: RTT ${RTT} ms — для синхронной репликации это много (>50 ms)"
        elif awk "BEGIN{exit !($RTT > 20)}"; then
          soso "узел $p: RTT ${RTT} ms — работать будет, но запись заметно медленнее (>20 ms)"
        else
          ok "узел $p доступен, RTT ${RTT} ms"
        fi
      else
        ok "узел $p доступен"
      fi
    else
      soso "узел $p не отвечает на ping (может быть закрыт ICMP — проверьте вручную)"
    fi

    for port in 3306 4567; do
      if command -v nc >/dev/null 2>&1; then
        if nc -z -w2 "$p" "$port" 2>/dev/null; then
          ok "порт $port на $p открыт"
        else
          soso "порт $port на $p закрыт (нормально, если узел ещё не установлен)"
        fi
      fi
    done
  done
else
  soso "PEERS не задан — пропускаю проверку связности с узлами"
fi

step "Конфликты портов"
for port in 5060 3306 8443; do
  if ss -tulnp 2>/dev/null | grep -q ":${port}\b"; then
    proc=$(ss -tulnp 2>/dev/null | awk -v p=":${port}" '$5 ~ p {print $NF; exit}')
    soso "порт $port уже занят: $proc"
  else
    ok "порт $port свободен"
  fi
done

step "Уже установленное ПО"
if command -v asterisk >/dev/null 2>&1; then
  soso "Asterisk уже установлен: $(asterisk -V 2>/dev/null). Версия обязана совпадать на всех узлах."
else
  ok "Asterisk не установлен (чистая система)"
fi
if command -v mysql >/dev/null 2>&1; then
  soso "MariaDB/MySQL уже установлен: $(mysql -V 2>/dev/null | head -1)"
else
  ok "MariaDB не установлена (чистая система)"
fi

step "SSH и firewall"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  if ufw status 2>/dev/null | grep -qE '(^22|/tcp.*22|OpenSSH)'; then
    ok "ufw активен, SSH разрешён"
  else
    bad "ufw активен, но правила для SSH (22/tcp) нет — при перезагрузке правил потеряете доступ"
  fi
else
  ok "ufw не активен — правила расставит установщик (SSH открывается первым)"
fi

printf '\n'
if [ "$FAILS" -gt 0 ]; then
  die "Проверок провалено: $FAILS, предупреждений: $WARNS. Исправьте FAIL и повторите."
fi
log "Готово: ошибок нет, предупреждений: $WARNS."
