# shellcheck shell=bash
#
# common.sh — общие функции для всех скриптов кластера.
# Подключается через:  . "$(dirname "$0")/lib/common.sh"
#
# Namespace: все функции без префикса, переменные — заглавными.

# ---------------------------------------------------------------- логирование

C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
[ -t 1 ] || { C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""; }

log()  { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_GRN" "$*" "$C_OFF"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
dbg()  { [ "${VERBOSE:-0}" = "1" ] && printf '%s    %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; return 0; }

# ------------------------------------------------------------------ окружение

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Запускать нужно от root (или через sudo)."
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Не найдена утилита '$c'. Установите её и повторите."
  done
}

# Определяет дистрибутив. Экспортирует OS_ID, OS_CODENAME, OS_VERSION_ID.
detect_os() {
  [ -r /etc/os-release ] || die "Нет /etc/os-release — неподдерживаемая ОС."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-unknown}"
  OS_VERSION_ID="${VERSION_ID:-unknown}"
  export OS_ID OS_CODENAME OS_VERSION_ID
}

# Проверяет, что ОС из списка поддерживаемых. Аргументы: bookworm bullseye ...
require_os_codename() {
  detect_os
  local want
  for want in "$@"; do
    [ "$OS_CODENAME" = "$want" ] && return 0
  done
  die "ОС '$OS_ID $OS_CODENAME' не поддерживается. Ожидается одна из: $*"
}

# ------------------------------------------------------------------ валидация

is_ipv4() {
  local ip="$1" o
  case "$ip" in
    *[!0-9.]*|"") return 1 ;;
  esac
  local IFS=. ; local -a parts
  read -r -a parts <<<"$ip"
  [ "${#parts[@]}" -eq 4 ] || return 1
  for o in "${parts[@]}"; do
    [ -n "$o" ] || return 1
    [ "$o" -le 255 ] 2>/dev/null || return 1
  done
  return 0
}

require_ipv4() {
  is_ipv4 "$2" || die "Параметр $1 должен быть корректным IPv4-адресом, получено: '$2'"
}

# Имя узла: [a-z0-9-], не длиннее 32 — оно же попадает в systemname Asterisk,
# в wsrep_node_name и в имя PJSIP-транка node-<name>, поэтому ограничение жёсткое.
require_node_name() {
  local n="$1"
  case "$n" in
    ''|*[!a-z0-9-]*) die "Имя узла '$n' некорректно: разрешены только a-z, 0-9 и дефис." ;;
  esac
  [ "${#n}" -le 32 ] || die "Имя узла '$n' длиннее 32 символов."
}

# ------------------------------------------------------------------- файлы

# Делает резервную копию файла перед перезаписью. Возвращает путь к копии.
backup_file() {
  local f="$1"
  [ -e "$f" ] || return 0
  # Объявление и присваивание раздельно: иначе код возврата date теряется
  # за успешным local (shellcheck SC2155).
  local bak
  bak="${f}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$bak"
  info "Бэкап: $bak"
}

# Рендерит шаблон: {{VAR}} -> значение переменной окружения VAR.
# Падает, если в результате остались неподставленные {{...}}.
#   render_tpl <шаблон> <куда> [права]
render_tpl() {
  local src="$1" dst="$2" mode="${3:-0644}"
  [ -r "$src" ] || die "Шаблон не найден: $src"

  local tmp; tmp="$(mktemp)"
  # Собираем sed-программу из всех {{VAR}}, встреченных в шаблоне.
  local sedprog="" var val
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    if [ -z "${!var+x}" ]; then
      rm -f "$tmp"
      die "Шаблон $src требует переменную '$var', но она не задана."
    fi
    val="${!var}"
    # Экранируем символы, значимые для sed-замены.
    val="${val//\\/\\\\}"; val="${val//&/\\&}"; val="${val//|/\\|}"
    val="${val//$'\n'/ }"
    sedprog+="s|{{${var}}}|${val}|g;"
  done < <(grep -o '{{[A-Z_][A-Z0-9_]*}}' "$src" | tr -d '{}' | sort -u)

  if [ -n "$sedprog" ]; then
    sed "$sedprog" "$src" >"$tmp"
  else
    cp "$src" "$tmp"
  fi

  if grep -q '{{[A-Z_][A-Z0-9_]*}}' "$tmp"; then
    local left; left="$(grep -o '{{[A-Z_][A-Z0-9_]*}}' "$tmp" | sort -u | tr '\n' ' ')"
    rm -f "$tmp"
    die "В $dst остались неподставленные переменные: $left"
  fi

  backup_file "$dst"
  install -D -m "$mode" "$tmp" "$dst"
  rm -f "$tmp"
  info "Записан $dst"
}

# Добавляет строку в файл, если её там ещё нет (идемпотентный include и т.п.).
ensure_line() {
  local line="$1" file="$2"
  [ -e "$file" ] || { install -D -m 0644 /dev/null "$file"; }
  grep -qxF "$line" "$file" && return 0
  backup_file "$file"
  printf '%s\n' "$line" >>"$file"
  info "В $file добавлено: $line"
}

# ------------------------------------------------------------------- пакеты

apt_quiet() {
  DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 -qq "$@"
}

apt_refresh_once() {
  [ "${_APT_REFRESHED:-0}" = "1" ] && return 0
  step "Обновление списка пакетов"
  apt_quiet update
  _APT_REFRESHED=1
}

# Ставит пакеты, пропуская уже установленные. Падает с внятным сообщением,
# если пакета нет в репозитории (в черновике это роняло скрипт на set -e).
ensure_pkg() {
  apt_refresh_once
  local missing=() p
  for p in "$@"; do
    if dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed"; then
      dbg "уже установлен: $p"
    else
      missing+=("$p")
    fi
  done
  [ "${#missing[@]}" -eq 0 ] && return 0

  local p_missing=()
  for p in "${missing[@]}"; do
    if ! apt-cache show "$p" >/dev/null 2>&1; then
      p_missing+=("$p")
    fi
  done
  if [ "${#p_missing[@]}" -gt 0 ]; then
    die "Пакеты отсутствуют в репозиториях: ${p_missing[*]}
Проверьте подключённые репозитории (для Asterisk нужен репозиторий Sangoma,
см. docs/02-lab-deploy.md, раздел «Единая версия Asterisk»)."
  fi

  info "Устанавливаю: ${missing[*]}"
  apt_quiet install -y "${missing[@]}"
}

# Первое имя пакета из списка, которое существует в репозитории.
# Нужно, т.к. res_odbc в Debian живёт в asterisk-modules, а в сборках
# Sangoma — отдельным пакетом. Черновик жёстко ставил несуществующий
# asterisk-odbc и падал.
first_available_pkg() {
  local p
  for p in "$@"; do
    if apt-cache show "$p" >/dev/null 2>&1; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------------- секреты

# Генерирует пароль, безопасный для .cnf/.ini/URL (без кавычек и спецсимволов).
gen_secret() {
  local len="${1:-32}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

# ------------------------------------------------------------------- MySQL

# Локальный mysql от root через unix_socket.
mysql_local() {
  mysql --protocol=socket -N -B "$@"
}

mysql_exec() {
  mysql_local -e "$1"
}

# Значение wsrep-статуса, пустая строка если недоступно.
wsrep_status() {
  mysql_local -e "SHOW STATUS LIKE '$1';" 2>/dev/null | awk 'NR==1{print $2}'
}

# Размер кластера как число; 0, если БД не отвечает.
# Всегда возвращает число — иначе арифметические сравнения падают под set -e.
cluster_size() {
  local v; v="$(wsrep_status wsrep_cluster_size)"
  case "$v" in
    ''|*[!0-9]*) printf '0' ;;
    *) printf '%s' "$v" ;;
  esac
}

wait_for_mysql() {
  local tries="${1:-60}" i
  for ((i = 0; i < tries; i++)); do
    if mysqladmin ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ------------------------------------------------------------------ Asterisk

asterisk_running() {
  asterisk -rx "core show version" >/dev/null 2>&1
}

# Мажорная версия Asterisk (18, 20, 21...). Пусто, если не определяется.
asterisk_major() {
  local v
  v="$(asterisk -V 2>/dev/null | sed -n 's/^Asterisk \([0-9][0-9]*\).*/\1/p')"
  printf '%s' "$v"
}

asterisk_reload() {
  asterisk -rx "module reload res_odbc.so"   >/dev/null 2>&1 || true
  asterisk -rx "module reload res_pjsip.so"  >/dev/null 2>&1 || true
  asterisk -rx "dialplan reload"             >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------- cluster.env

# Загружает config/cluster.env (если есть). Значения из окружения имеют
# приоритет над файлом — удобно для CI и разовых переопределений.
load_cluster_env() {
  local f="${1:-}"
  [ -n "$f" ] || f="${REPO_ROOT:-.}/config/cluster.env"
  [ -r "$f" ] || return 0
  local line key val
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"; val="${line#*=}"
    key="${key// /}"
    [ -n "$key" ] || continue
    # окружение важнее файла
    if [ -z "${!key+x}" ]; then
      val="${val%\"}"; val="${val#\"}"
      export "$key=$val"
    fi
  done <"$f"
  dbg "Загружен $f"
}

# Корень репозитория относительно вызывающего скрипта.
repo_root_from() {
  cd "$(dirname "$1")/.." && pwd
}
