; /etc/asterisk/res_odbc.conf

[asterisk-galera]
enabled => yes
dsn => asterisk-galera
username => {{RT_USER}}
password => {{RT_PASS}}

; Пул соединений: realtime PJSIP при каждой регистрации делает несколько
; запросов. limit=1 из черновика сериализует их в одно соединение и на
; сотне телефонов превращается в узкое место.
pooling => yes
limit => 10
shared_connections => no

pre-connect => yes
sanitysql => select 1
connect_timeout => 5

; Переподключаться, не дожидаясь запроса — важно при рестарте локального
; узла Galera (например, после SST).
idlecheck => 60
forcecommit => no
isolation => read_committed
