; /etc/asterisk/extensions_master_hook.conf — кластерный хук для МАСТЕРА.
;
; Подключается из extensions_custom.conf. FreePBX включает контекст
; [from-internal-custom] первым внутри [from-internal], поэтому совпадение
; здесь перехватывает набор до штатной обработки FreePBX.
;
; Задача: если вызываемый абонент зарегистрирован на другой площадке —
; отдать вызов туда через межузловой транк. Если он здесь либо нигде —
; вернуть управление FreePBX (from-internal-additional), чтобы отработали
; голосовая почта, переадресации, Follow Me и прочая штатная логика.
;
; Длина внутренних номеров. Проверка дампа боевой АТС показала, что план
; нумерации смешанный: есть 3-значные (201-481), 4-значные и 5-значные
; (10888-10999). Покрыты все три — иначе часть абонентов не маршрутизируется
; между площадками и вызовы к ним молча остаются локальными.
;
; Свой набор длин смотрите так:
;   ./scripts/check-numbering.py --dump <площадка>=<дамп.sql>
;
; Если появится 6-значный план — добавьте строку по образцу.

[from-internal-custom]

exten => _XXX,1,Gosub(cluster-maybe-remote,${EXTEN},1)
exten => _XXXX,1,Gosub(cluster-maybe-remote,${EXTEN},1)
exten => _XXXXX,1,Gosub(cluster-maybe-remote,${EXTEN},1)

;-----------------------------------------------------------------------------
; Решает, вести вызов через кластер или отдать FreePBX.
;-----------------------------------------------------------------------------
[cluster-maybe-remote]
exten => _X.,1,NoOp(Cluster check for ${EXTEN} on ${CLUSTER_NODE})
	same => n,Set(NODE=${ODBC_CONTACT_NODE(${EXTEN})})
	same => n,NoOp(${EXTEN} registered on node '${NODE}')

	; Нигде не зарегистрирован — пусть FreePBX отработает недоступность
	; (голосовая почта, Follow Me, переадресация по недоступности).
	same => n,GotoIf($["${NODE}" = ""]?freepbx)

	; Зарегистрирован здесь — обычная обработка FreePBX.
	same => n,GotoIf($["${NODE}" = "${CLUSTER_NODE}"]?freepbx)

	; Зарегистрирован на другой площадке — ведём туда.
	same => n,NoOp(Routing ${EXTEN} to remote node ${NODE})
	same => n,Dial(PJSIP/${EXTEN}@node-${NODE},${CLUSTER_DIALTIMEOUT},g)
	same => n,NoOp(Remote leg ${DIALSTATUS})
	; Транк до площадки мёртв — отдаём FreePBX, там сработает штатный
	; сценарий недоступности вместо тишины в трубке.
	same => n,GotoIf($["${DIALSTATUS}" = "CHANUNAVAIL"]?freepbx)
	same => n,GotoIf($["${DIALSTATUS}" = "CONGESTION"]?freepbx)
	same => n,Hangup()

	; Возврат в штатный диалплан FreePBX.
	same => n(freepbx),NoOp(Handing ${EXTEN} back to FreePBX)
	same => n,Goto(from-internal-additional,${EXTEN},1)
