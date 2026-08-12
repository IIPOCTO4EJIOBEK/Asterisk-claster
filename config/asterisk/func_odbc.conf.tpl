; /etc/asterisk/func_odbc.conf — запросы к общей БД из диалплана.
;
; Ключевой механизм межузловой маршрутизации: узнать, на КАКОЙ площадке
; сейчас физически зарегистрирован абонент.
;
; Работает это так: у каждого узла в asterisk.conf задан systemname, и
; res_pjsip записывает его в ps_contacts.reg_server при регистрации телефона.
; Значит, по номеру можно узнать имя узла, а по имени узла — межузловой транк
; node-<имя> (см. pjsip_nodes.conf, генерируется make-node-trunks.sh).

; Узел, на котором зарегистрирован абонент. Пусто — абонент не в сети нигде.
; Берём самый свежий контакт: телефон мог "перетечь" на резервный узел,
; не успев разрегистрироваться на основном.
[CONTACT_NODE]
dsn=asterisk-galera
readsql=SELECT reg_server FROM ps_contacts WHERE endpoint='${SQL_ESC(${ARG1})}' AND reg_server IS NOT NULL AND reg_server <> '' ORDER BY expiration_time DESC LIMIT 1

; Сколько активных контактов у абонента во всём кластере.
[CONTACT_COUNT]
dsn=asterisk-galera
readsql=SELECT COUNT(*) FROM ps_contacts WHERE endpoint='${SQL_ESC(${ARG1})}'

; Проверка, что такой добавочный вообще существует в кластере.
[ENDPOINT_EXISTS]
dsn=asterisk-galera
readsql=SELECT COUNT(*) FROM ps_endpoints WHERE id='${SQL_ESC(${ARG1})}'

; Домашняя площадка абонента (куда его тянуть, если он нигде не зарегистрирован
; — например, для голосовой почты). Заполняется в phone_provision.
[HOME_NODE]
dsn=asterisk-galera
readsql=SELECT home_node FROM phone_provision WHERE extension='${SQL_ESC(${ARG1})}' LIMIT 1
