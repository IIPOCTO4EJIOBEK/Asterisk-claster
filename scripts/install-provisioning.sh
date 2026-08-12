#!/bin/bash
#
# install-provisioning.sh — сервер автопровижининга (nginx + php-fpm).
# Вызывается из install-master.sh, но можно запускать и отдельно.
#
#   ./scripts/install-provisioning.sh --db-name=asterisk --db-user=prov_ro \
#      --db-pass=... --hmac-secret=... --port=8443 --phone-cidr=10.0.0.0/8 \
#      --node-ip=10.10.10.11
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/common.sh
. "$REPO_ROOT/scripts/lib/common.sh"

PROV_CONFIG=/etc/asterisk-cluster/provisioning.php
PROV_PORT=8443
REGISTER_EXPIRES=600
SIP_PORT=5060
STATIC_TOKEN=""
REQUIRE_TOKEN=1

for arg in "$@"; do
  case $arg in
    --db-name=*)      DB_NAME="${arg#*=}" ;;
    --db-user=*)      PROV_DB_USER="${arg#*=}" ;;
    --db-pass=*)      PROV_DB_PASS="${arg#*=}" ;;
    --hmac-secret=*)  PROV_HMAC_SECRET="${arg#*=}" ;;
    --static-token=*) STATIC_TOKEN="${arg#*=}" ;;
    --no-token)       REQUIRE_TOKEN=0 ;;
    --port=*)         PROV_PORT="${arg#*=}" ;;
    --phone-cidr=*)   PHONE_CIDR="${arg#*=}" ;;
    --node-ip=*)      NODE_IP="${arg#*=}" ;;
    --sip-port=*)     SIP_PORT="${arg#*=}" ;;
    --expires=*)      REGISTER_EXPIRES="${arg#*=}" ;;
    -h|--help)        sed -n '2,10p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
: "${DB_NAME:?--db-name обязателен}"
: "${PROV_DB_USER:?--db-user обязателен}"
: "${PROV_DB_PASS:?--db-pass обязателен}"
: "${PROV_HMAC_SECRET:?--hmac-secret обязателен}"
: "${NODE_IP:?--node-ip обязателен}"
: "${PHONE_CIDR:=10.0.0.0/8}"

step "Пакеты"
ensure_pkg nginx php-fpm php-mysql php-cli openssl

# Версия PHP и путь к сокету определяются, а не угадываются: в черновике в
# конфиге nginx стоял /run/php/php-fpm.sock, которого в Debian не существует
# (реальное имя — php8.2-fpm.sock), и провижининг отдавал 502.
PHP_FPM_SOCKET="$(find /run/php -maxdepth 1 -name 'php*-fpm.sock' 2>/dev/null | sort | tail -1)"
if [ -z "$PHP_FPM_SOCKET" ]; then
  PHP_VER="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  [ -n "$PHP_VER" ] || die "Не удалось определить версию PHP."
  systemctl enable --now "php${PHP_VER}-fpm" >/dev/null 2>&1 || true
  sleep 2
  PHP_FPM_SOCKET="$(find /run/php -maxdepth 1 -name 'php*-fpm.sock' 2>/dev/null | sort | tail -1)"
fi
[ -n "$PHP_FPM_SOCKET" ] || die "Не найден сокет php-fpm в /run/php. Проверьте: systemctl status php*-fpm"
info "Сокет php-fpm: $PHP_FPM_SOCKET"

PHP_FPM_SERVICE="$(systemctl list-units --type=service --all --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}' | head -1)"
: "${PHP_FPM_SERVICE:=php-fpm.service}"

step "Файлы приложения"
# Раскладка: приложение целиком в PROV_APP, наружу через nginx смотрит
# только PROV_APP/public. src/ и templates/ лежат вне web root, поэтому
# исходники и шаблоны нельзя скачать по HTTP даже при ошибке в конфиге.
PROV_APP=/var/www/provisioning
PROV_ROOT="$PROV_APP/public"

install -d -m 0755 "$PROV_APP" "$PROV_ROOT" "$PROV_APP/src" "$PROV_APP/templates" "$PROV_APP/tools"
install -m 0644 "$REPO_ROOT/provisioning/public/index.php"     "$PROV_ROOT/index.php"
install -m 0644 "$REPO_ROOT/provisioning/src/Provisioner.php"  "$PROV_APP/src/Provisioner.php"
install -m 0644 "$REPO_ROOT/provisioning/tools/phonectl.php"   "$PROV_APP/tools/phonectl.php"
for t in "$REPO_ROOT"/provisioning/templates/*.php; do
  install -m 0644 "$t" "$PROV_APP/templates/$(basename "$t")"
done
info "Приложение развёрнуто в $PROV_APP (web root: $PROV_ROOT)"

# phonectl.php подключает ../src/Provisioner.php относительно себя, поэтому
# в /usr/local/bin кладём обёртку, а не сам файл.
cat >/usr/local/bin/phonectl <<EOF
#!/bin/sh
# Обёртка над $PROV_APP/tools/phonectl.php
exec /usr/bin/php "$PROV_APP/tools/phonectl.php" "\$@"
EOF
chmod 0755 /usr/local/bin/phonectl
info "Утилита управления: /usr/local/bin/phonectl"

step "Конфигурация приложения"
install -d -m 0750 /etc/asterisk-cluster
backup_file "$PROV_CONFIG"
cat >"$PROV_CONFIG" <<EOF
<?php
// Сгенерировано install-provisioning.sh $(date -Is). Содержит пароль БД.
return [
    'db_host'      => '127.0.0.1',
    'db_port'      => 3306,
    'db_name'      => '${DB_NAME}',
    'db_user'      => '${PROV_DB_USER}',
    'db_pass'      => '${PROV_DB_PASS}',

    // Для phonectl: запись в phone_provision идёт под root через unix-сокет.
    'admin_db_socket' => '/run/mysqld/mysqld.sock',
    'admin_db_user'   => 'root',
    'admin_db_pass'   => '',

    'template_dir' => '${PROV_APP}/templates',

    // Слой 1: с каких подсетей принимаются запросы. Пустой массив = без
    // ограничения по сети (не рекомендуется).
    'allowed_cidrs' => ['${PHONE_CIDR}'],

    // Слой 2: токен в URL.
    'require_token' => ${REQUIRE_TOKEN},
    'hmac_secret'   => '${PROV_HMAC_SECRET}',
    'static_token'  => '${STATIC_TOKEN}',

    'sip_port'         => ${SIP_PORT},
    // Интервал перерегистрации телефона. 600 с вместо 60 из черновика:
    // каждая регистрация — это запись в общую таблицу ps_contacts, которая
    // синхронно реплицируется на все площадки.
    'register_expires' => ${REGISTER_EXPIRES},

    'public_host'   => '${NODE_IP}',
    'public_port'   => ${PROV_PORT},
    'public_scheme' => 'https',
];
EOF
chmod 0640 "$PROV_CONFIG"
chown root:www-data "$PROV_CONFIG"
info "Записан $PROV_CONFIG (0640, root:www-data)"

step "TLS-сертификат"
PROV_TLS_CERT=/etc/asterisk-cluster/provisioning.crt
PROV_TLS_KEY=/etc/asterisk-cluster/provisioning.key
if [ ! -f "$PROV_TLS_CERT" ]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout "$PROV_TLS_KEY" -out "$PROV_TLS_CERT" \
    -subj "/CN=${NODE_IP}" -addext "subjectAltName=IP:${NODE_IP}" >/dev/null 2>&1
  chmod 0640 "$PROV_TLS_KEY"; chown root:www-data "$PROV_TLS_KEY"
  info "Создан самоподписанный сертификат на 10 лет"
else
  info "Сертификат уже есть — оставляю"
fi

step "nginx"
export PROV_PORT NODE_IP PROV_ROOT PROV_CONFIG PHP_FPM_SOCKET PROV_TLS_CERT PROV_TLS_KEY
render_tpl "$REPO_ROOT/config/nginx/provisioning.conf.tpl" \
           /etc/nginx/sites-available/provisioning 0644
ln -sfn /etc/nginx/sites-available/provisioning /etc/nginx/sites-enabled/provisioning

if nginx -t >/dev/null 2>&1; then
  systemctl reload nginx || systemctl restart nginx
  info "nginx перезагружен"
else
  nginx -t || true
  die "Конфигурация nginx не проходит проверку — исправьте и повторите."
fi
systemctl restart "$PHP_FPM_SERVICE" >/dev/null 2>&1 || true

cat <<EOF

Провижининг поднят: https://${NODE_IP}:${PROV_PORT}/prov/<MAC>.cfg

Порядок ввода телефона в работу:
  phonectl add 00:15:65:aa:bb:cc 564 --vendor=yealink \\
      --primary=<ip площадки> --backup=<ip мастера> --home=<имя площадки>
  phonectl arm 001565aabbcc --minutes=30    # окно на время установки
  phonectl log --limit=20                   # проверить, что телефон забрал конфиг

Пароль отдаётся только внутри открытого окна — знание MAC само по себе
доступа не даёт. Подробности и модель угроз: docs/07-security.md

EOF
