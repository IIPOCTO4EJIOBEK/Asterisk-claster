; /etc/asterisk/pjsip_local_trunk.conf — транк провайдера ЭТОЙ площадки.
;
; Генерируется scripts/setup-local-trunk.sh. Файл локальный и намеренно НЕ
; в realtime: таблица ps_registrations общая на кластер и не различает узлы,
; поэтому вынесенный туда транк заставил бы регистрироваться все площадки
; сразу одним аккаунтом.
;
; Узел:     {{NODE_NAME}}
; Транк:    {{TRUNK_NAME}}
; Провайдер: {{TRUNK_HOST}}

;--- Учётные данные -----------------------------------------------------------
[{{TRUNK_NAME}}-auth]
type=auth
auth_type=userpass
username={{TRUNK_USER}}
password={{TRUNK_PASS}}

;--- Регистрация на стороне провайдера ----------------------------------------
[{{TRUNK_NAME}}-reg]
type=registration
transport=transport-udp
outbound_auth={{TRUNK_NAME}}-auth
server_uri=sip:{{TRUNK_HOST}}
client_uri=sip:{{TRUNK_USER}}@{{TRUNK_HOST}}
contact_user={{TRUNK_USER}}
retry_interval=60
forbidden_retry_interval=600
expiration={{TRUNK_EXPIRY}}
; Одна регистрация на узел. Оператор допускает несколько точек подключения,
; но каждая площадка обязана регистрироваться СВОИМ аккаунтом — иначе
; входящий вызов уйдёт на случайный узел.
line=yes
endpoint={{TRUNK_NAME}}

;--- Точка подключения --------------------------------------------------------
[{{TRUNK_NAME}}]
type=endpoint
transport=transport-udp
context={{TRUNK_CONTEXT}}
disallow=all
; alaw первым: российские операторы работают на нём, иначе транскодирование
; на каждом внешнем вызове.
allow=alaw,ulaw
outbound_auth={{TRUNK_NAME}}-auth
aors={{TRUNK_NAME}}
from_user={{TRUNK_USER}}
from_domain={{TRUNK_HOST}}
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
ice_support=no
send_rpid=yes
trust_id_inbound=no
; Вызов «наружу» не должен приниматься как внутренний абонент.
identify_by=username,ip
language=ru

[{{TRUNK_NAME}}]
type=aor
contact=sip:{{TRUNK_HOST}}
qualify_frequency=60
qualify_timeout=5

;--- Опознание входящих по адресу провайдера ----------------------------------
[{{TRUNK_NAME}}]
type=identify
endpoint={{TRUNK_NAME}}
match={{TRUNK_HOST}}
