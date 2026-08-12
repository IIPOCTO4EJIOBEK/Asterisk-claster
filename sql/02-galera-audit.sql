-- Аудит схемы на совместимость с Galera.
-- Запуск:  mysql < sql/02-galera-audit.sql
--
-- Galera реплицирует только InnoDB и плохо работает с таблицами без
-- первичного ключа. Схема FreePBX содержит и то, и другое, поэтому
-- проверять стоит и до включения репликации, и после обновлений FreePBX.

SELECT '=== Таблицы не в InnoDB (НЕ реплицируются, узлы разойдутся) ===' AS '';

SELECT table_schema AS "База",
       table_name   AS "Таблица",
       engine       AS "Движок",
       ROUND((data_length + index_length) / 1024 / 1024, 1) AS "МБ"
FROM information_schema.tables
WHERE table_schema IN ('asterisk', 'asteriskcdrdb')
  AND engine IS NOT NULL
  AND engine <> 'InnoDB'
ORDER BY table_schema, table_name;

SELECT '' AS '';
SELECT '=== Таблицы без первичного ключа (репликация неэффективна) ===' AS '';

SELECT t.table_schema AS "База",
       t.table_name   AS "Таблица",
       t.table_rows   AS "Строк (примерно)"
FROM information_schema.tables t
LEFT JOIN information_schema.table_constraints c
       ON c.table_schema = t.table_schema
      AND c.table_name   = t.table_name
      AND c.constraint_type = 'PRIMARY KEY'
WHERE t.table_schema IN ('asterisk', 'asteriskcdrdb')
  AND t.table_type = 'BASE TABLE'
  AND c.constraint_name IS NULL
ORDER BY t.table_rows DESC;

SELECT '' AS '';
SELECT '=== Состояние кластера ===' AS '';

SHOW STATUS LIKE 'wsrep_cluster_size';
SHOW STATUS LIKE 'wsrep_cluster_status';
SHOW STATUS LIKE 'wsrep_local_state_comment';
SHOW STATUS LIKE 'wsrep_ready';

SELECT '' AS '';
SELECT '=== Нагрузка репликации (признаки перегрузки) ===' AS '';
-- flow_control_paused > 0.1 — какой-то узел тормозит весь кластер.
-- Растущие cert_failures на телефонии почти всегда означают слишком
-- частую запись в ps_contacts: увеличьте register_expires.
SHOW STATUS LIKE 'wsrep_flow_control_paused';
SHOW STATUS LIKE 'wsrep_local_recv_queue_avg';
SHOW STATUS LIKE 'wsrep_local_cert_failures';

SELECT '' AS '';
SELECT '=== Регистрации по площадкам ===' AS '';
-- Пустой reg_server означает, что на узле не задан systemname,
-- и межузловая маршрутизация к этим абонентам работать не будет.

SELECT IFNULL(NULLIF(reg_server, ''), '(не задан systemname!)') AS "Площадка",
       COUNT(*) AS "Телефонов"
FROM asterisk.ps_contacts
GROUP BY reg_server
ORDER BY 2 DESC;

SELECT '' AS '';
SELECT '=== Размер realtime-таблиц ===' AS '';

SELECT table_name AS "Таблица",
       table_rows AS "Строк"
FROM information_schema.tables
WHERE table_schema = 'asterisk'
  AND table_name LIKE 'ps\_%'
ORDER BY table_rows DESC;
