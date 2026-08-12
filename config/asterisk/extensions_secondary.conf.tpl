; /etc/asterisk/extensions.conf для headless secondary-узла.
;
; Мастер работает под FreePBX и имеет свой сгенерированный диалплан —
; он приезжает сюда через scripts/push-dialplan.sh в /etc/asterisk/from-master/.
; Этот файл — точка входа, которая подключает и то, и другое.

[general]
static=yes
writeprotect=no
clearglobalvars=no

#include "extensions_cluster.conf"

; Диалплан, отрендеренный FreePBX на мастере и синхронизированный сюда.
; Файл может отсутствовать до первого запуска push-dialplan.sh — Asterisk
; переживёт отсутствие include без ошибки запуска.
#include "from-master/extensions_master.conf"

;-----------------------------------------------------------------------------
; Контекст для абонентов, зарегистрированных на этом узле.
; Realtime-endpoint'ы приезжают из общей БД с context=from-site.
;-----------------------------------------------------------------------------
[from-site]
include => cluster-diag

; Внутренние номера — через кластерный поиск.
; После возврата из cluster-dial проверяем DIALSTATUS: без этой проверки
; абонент слышал бы «недоступен» даже после успешно завершённого разговора,
; потому что диалплан продолжается после того, как собеседник положил трубку.
exten => _XXX,1,Gosub(cluster-dial,${EXTEN},1)
	same => n,GotoIf($["${DIALSTATUS}" = "ANSWER"]?done)
	same => n,Goto(unavail-handler,${EXTEN},1)
	same => n(done),Hangup()

exten => _XXXX,1,Gosub(cluster-dial,${EXTEN},1)
	same => n,GotoIf($["${DIALSTATUS}" = "ANSWER"]?done)
	same => n,Goto(unavail-handler,${EXTEN},1)
	same => n(done),Hangup()

; Внешние вызовы: сначала свой транк, при его недоступности — через мастер.
;
; Оператор допускает несколько точек подключения к виртуальной АТС, поэтому
; у площадки есть собственная регистрация (setup-local-trunk.sh). Отказ
; мастера при этом не оставляет площадку без внешней связи.
;
; Если LOCAL_TRUNK пуст, транка у площадки нет — сразу идём через мастер.
exten => _X.,1,NoOp(Внешний вызов ${EXTEN}, локальный транк: ${LOCAL_TRUNK})
	same => n,GotoIf($["${LOCAL_TRUNK}" = ""]?viamaster)

	same => n,Dial(PJSIP/${EXTEN}@${LOCAL_TRUNK},60)
	same => n,NoOp(Локальный транк вернул ${DIALSTATUS})
	; Оператор недоступен или отверг вызов по перегрузке — пробуем мастер.
	same => n,GotoIf($["${DIALSTATUS}" = "CHANUNAVAIL"]?viamaster)
	same => n,GotoIf($["${DIALSTATUS}" = "CONGESTION"]?viamaster)
	same => n,Hangup()

	; BUSY и NOANSWER через мастер не повторяем: абонент на той стороне
	; ответил отказом, и второй звонок ему же — это уже не отказоустойчивость.
	same => n(viamaster),NoOp(Внешний вызов ${EXTEN} через мастер)
	same => n,Dial(PJSIP/${EXTEN}@node-{{MASTER_NODE_NAME}},60)
	same => n,Hangup()

[unavail-handler]
exten => _X.,1,NoOp(${EXTEN} unavailable, status=${DIALSTATUS})
	same => n,Playback(vm-nobodyavail)
	same => n,Hangup()
