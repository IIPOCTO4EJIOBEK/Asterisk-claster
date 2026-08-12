; /etc/asterisk/extensions_cluster.conf — межузловая маршрутизация.
;
; Подключается через #include из extensions.conf (secondary) или
; extensions_custom.conf (мастер под FreePBX).
;
; Решает задачу, которой в черновике не было вообще: звонок пришёл на узел А,
; а вызываемый абонент зарегистрирован на узле Б — надо доставить вызов туда.
;
; Логика: спросить у общей БД, где живёт контакт, и либо позвонить локально,
; либо перебросить по межузловому транку node-<узел>.

[globals]
CLUSTER_NODE={{NODE_NAME}}
; Таймаут дозвона до абонента, секунды.
CLUSTER_DIALTIMEOUT=30
; Таймаут установления межузлового плеча — короткий, чтобы при мёртвом узле
; быстро свалиться в failover, а не держать вызывающего.
CLUSTER_TRUNKTIMEOUT=8

;-----------------------------------------------------------------------------
; Вызов внутреннего номера с учётом того, где он зарегистрирован.
; Использование из своего диалплана:  Gosub(cluster-dial,${EXTEN},1)
;-----------------------------------------------------------------------------
[cluster-dial]
exten => _X.,1,NoOp(Cluster dial ${EXTEN} from node ${CLUSTER_NODE})
	same => n,Set(TARGET=${EXTEN})
	same => n,Set(NODE=${ODBC_CONTACT_NODE(${TARGET})})
	same => n,NoOp(Contact node for ${TARGET}: '${NODE}')

	; Нигде не зарегистрирован — сразу на недоступность (голосовая почта и т.п.)
	same => n,GotoIf($["${NODE}" = ""]?unavailable)

	; Зарегистрирован здесь — обычный локальный вызов.
	same => n,GotoIf($["${NODE}" = "${CLUSTER_NODE}"]?local)

	; Зарегистрирован на другом узле — идём через межузловой транк.
	same => n,Goto(remote)

	same => n(local),NoOp(Local delivery to ${TARGET})
	same => n,Dial(PJSIP/${TARGET},${CLUSTER_DIALTIMEOUT})
	same => n,Goto(after)

	same => n(remote),NoOp(Routing ${TARGET} to node ${NODE})
	same => n,Dial(PJSIP/${TARGET}@node-${NODE},${CLUSTER_DIALTIMEOUT},g)
	same => n,NoOp(Remote leg result: ${DIALSTATUS})
	; Узел не ответил (сеть/упал) — пробуем локально: телефон мог уже
	; перерегистрироваться сюда, а запись в ps_contacts ещё не протухла.
	same => n,GotoIf($["${DIALSTATUS}" = "CHANUNAVAIL"]?local)
	same => n,GotoIf($["${DIALSTATUS}" = "CONGESTION"]?local)
	same => n,Goto(after)

	same => n(unavailable),NoOp(${TARGET} is not registered anywhere in cluster)
	same => n,Set(DIALSTATUS=CHANUNAVAIL)

	same => n(after),Return()

;-----------------------------------------------------------------------------
; Входящий контекст межузловых транков.
; Сюда попадают вызовы, переброшенные с других узлов кластера.
; Доставляем строго локально, без повторного поиска по кластеру, — иначе
; при рассинхроне ps_contacts вызов может зациклиться между узлами.
;-----------------------------------------------------------------------------
[from-cluster]
exten => _X.,1,NoOp(Inbound from cluster node, target ${EXTEN})
	same => n,Set(__CLUSTER_HOP=1)
	same => n,Dial(PJSIP/${EXTEN},${CLUSTER_DIALTIMEOUT})
	same => n,Hangup()

;-----------------------------------------------------------------------------
; Диагностика: набрать *777 — узел назовёт своё имя и состояние кластера.
; Полезно при проверке failover: слышно, какая площадка обслуживает звонок.
;-----------------------------------------------------------------------------
[cluster-diag]
exten => *777,1,Answer()
	same => n,Wait(1)
	same => n,SayAlpha(${CLUSTER_NODE})
	same => n,Wait(1)
	same => n,Hangup()
