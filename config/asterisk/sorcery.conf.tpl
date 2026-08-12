; /etc/asterisk/sorcery.conf
;
; Без этой секции res_pjsip не пойдёт в realtime даже при заполненном
; extconfig.conf — в черновике файла не было вовсе.
;
; Порядок важен: сначала статика (transport/global из pjsip.conf и межузловые
; транки из pjsip_nodes.conf), затем realtime из общей БД.

[res_pjsip]
endpoint=config,pjsip.conf,criteria=type=endpoint
endpoint=realtime,ps_endpoints
auth=config,pjsip.conf,criteria=type=auth
auth=realtime,ps_auths
aor=config,pjsip.conf,criteria=type=aor
aor=realtime,ps_aors
domain_alias=realtime,ps_domain_aliases

[res_pjsip_endpoint_identifier_ip]
identify=config,pjsip.conf,criteria=type=identify
identify=realtime,ps_endpoint_id_ips

[res_pjsip_registrar]
; Контакты — только realtime. Общая таблица на весь кластер.
contact=realtime,ps_contacts

[res_pjsip_outbound_registration]
registration=realtime,ps_registrations
