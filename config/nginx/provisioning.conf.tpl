# /etc/nginx/sites-available/provisioning
#
# Провижининг отдаёт телефонам их SIP-пароли, поэтому:
#   - только HTTPS (в черновике был открытый HTTP на 8080);
#   - ограничение частоты запросов, чтобы MAC-адреса нельзя было перебрать;
#   - лог отдельным файлом для разбора инцидентов.
#
# Сертификат по умолчанию самоподписанный: телефоны обычно не проверяют
# цепочку, но если ваша модель проверяет — положите сюда нормальный
# сертификат (см. docs/07-security.md).

# Зона ограничения частоты: 10 запросов в минуту с адреса.
limit_req_zone $binary_remote_addr zone=prov_limit:10m rate=10r/m;

server {
    listen {{PROV_PORT}} ssl;
    listen [::]:{{PROV_PORT}} ssl;
    http2 on;

    server_name {{NODE_IP}};

    ssl_certificate     {{PROV_TLS_CERT}};
    ssl_certificate_key {{PROV_TLS_KEY}};
    ssl_protocols       TLSv1.2 TLSv1.3;
    # Старые телефоны нередко не умеют TLS 1.3 и современные шифры —
    # набор намеренно шире, чем для веб-сервера.
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:PROV:5m;

    root {{PROV_ROOT}};
    index index.php;

    access_log /var/log/nginx/provisioning-access.log;
    error_log  /var/log/nginx/provisioning-error.log warn;

    # Конфиг телефона не должен попадать в кэши промежуточных узлов.
    add_header Cache-Control "no-store" always;
    add_header X-Content-Type-Options "nosniff" always;

    server_tokens off;
    client_max_body_size 1k;

    # Основной путь. Форма имени файла у вендоров разная:
    #   Yealink      <MAC>.cfg      (в URL провижининга подставляется $MAC)
    #   Fanvil       <mac>.cfg      ($mac)
    #   Grandstream  cfg<MAC>.xml   (префикс cfg добавляет сама прошивка)
    # Регулярное выражение принимает все три варианта.
    location ~ ^/prov/(?:cfg)?([0-9a-fA-F]{12})\.(cfg|xml|txt)$ {
        limit_req zone=prov_limit burst=5 nodelay;
        try_files /dev/null @php;
    }

    location = /index.php {
        limit_req zone=prov_limit burst=5 nodelay;
        try_files /dev/null @php;
    }

    location @php {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:{{PHP_FPM_SOCKET}};
        fastcgi_param SCRIPT_FILENAME {{PROV_ROOT}}/index.php;
        fastcgi_param PROV_CONFIG {{PROV_CONFIG}};
    }

    # Всё остальное закрыто: каталог с шаблонами и исходниками наружу
    # не отдаётся ни при каких условиях.
    location / {
        return 404;
    }
}
