# /etc/odbc.ini — DSN для Asterisk realtime.
#
# Имя драйвера ДОЛЖНО совпадать с секцией из /etc/odbcinst.ini.
# Пакет odbc-mariadb в Debian регистрирует драйвер как "MariaDB Unicode",
# а не "MariaDB" (в черновике было именно это, и подключение не поднималось).
# Скрипты подставляют сюда реальное имя, найденное через `odbcinst -q -d`.

[asterisk-galera]
Description = Asterisk Realtime via Galera
Driver      = {{ODBC_DRIVER_NAME}}
Server      = 127.0.0.1
Port        = 3306
Database    = {{DB_NAME}}
Charset     = utf8mb4
