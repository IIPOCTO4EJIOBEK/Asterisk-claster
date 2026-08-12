; /etc/asterisk/pjsip_transport.conf — транспорт и глобальные параметры узла.
; Подключается из pjsip.conf (secondary) или pjsip_custom.conf (мастер/FreePBX).
;
; Это единственная часть PJSIP, которая у каждого узла своя, — поэтому она
; не в realtime.

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:{{SIP_PORT}}
external_media_address={{NODE_IP}}
external_signaling_address={{NODE_IP}}
local_net={{LOCAL_NET}}

[global]
type=global
; В черновике было auth_username,ip,anonymous. Без username обычные телефоны,
; которые шлют From без auth-заголовка на первом INVITE, не опознаются.
; Правильный порядок: сперва по username, затем по IP (транки), затем аноним.
endpoint_identifier_order=username,auth_username,ip,anonymous
; Имя узла в Contact/User-Agent — помогает при разборе логов между площадками.
user_agent=Asterisk-{{NODE_NAME}}
; Максимум одновременных исходящих регистраций/OPTIONS в очереди.
max_initial_qualify_time=30
keep_alive_interval=30
