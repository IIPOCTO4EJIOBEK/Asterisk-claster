; /etc/asterisk/extconfig.conf — какие сущности читаются из общей БД.
;
; В черновике здесь были только ps_endpoints/ps_aors/ps_auths/ps_registrations,
; и из-за этого не работало главное: ps_contacts (регистрации телефонов)
; хранились локально в astdb, узлы не видели регистраций друг друга, а звонок
; между площадками маршрутизировать было не по чему.
;
; ps_registrations — это ИСХОДЯЩИЕ регистрации Asterisk на транки провайдера,
; а не регистрации абонентов. Абоненты живут в ps_contacts.

[settings]

; --- PJSIP realtime ---------------------------------------------------------
ps_endpoints => odbc,asterisk-galera,ps_endpoints
ps_auths => odbc,asterisk-galera,ps_auths
ps_aors => odbc,asterisk-galera,ps_aors

; Регистрации абонентов. Общие для всего кластера — на этом держится
; межузловая маршрутизация (см. func_odbc.conf / extensions_cluster.conf).
ps_contacts => odbc,asterisk-galera,ps_contacts

; Идентификация по IP (транки провайдеров и межузловые транки).
ps_endpoint_id_ips => odbc,asterisk-galera,ps_endpoint_id_ips

; Исходящие регистрации на транки провайдеров.
ps_registrations => odbc,asterisk-galera,ps_registrations

; Домены/алиасы — нужны, если абоненты регистрируются по FQDN площадки.
ps_domain_aliases => odbc,asterisk-galera,ps_domain_aliases

; --- прочее -----------------------------------------------------------------
; Транспорты и globals НЕ выносим в realtime сознательно: они у каждого узла
; свои (свой внешний IP, свой systemname). Держим их в статических файлах.

; Голосовая почта — общая на кластер, чтобы сообщение было доступно с любой
; площадки. Требует таблицу voicemail_messages (создаётся alembic-схемой).
voicemail => odbc,asterisk-galera,voicemail_messages
