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

; Всё, что длиннее внутреннего плана, — наружу через мастер.
; Транки провайдеров держим на мастере, secondary отдаёт исходящие туда;
; если мастер недоступен — звонок не проходит, и это осознанный компромисс
; лабораторной схемы (см. docs/04-production-rollout.md про локальные транки).
exten => _X.,1,NoOp(Outbound ${EXTEN} via master)
	same => n,Dial(PJSIP/${EXTEN}@node-{{MASTER_NODE_NAME}},60)
	same => n,Hangup()

[unavail-handler]
exten => _X.,1,NoOp(${EXTEN} unavailable, status=${DIALSTATUS})
	same => n,Playback(vm-nobodyavail)
	same => n,Hangup()
