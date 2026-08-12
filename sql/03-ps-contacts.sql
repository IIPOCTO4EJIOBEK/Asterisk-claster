-- ps_contacts — таблица регистраций абонентов для realtime.
--
-- Обычно её создаёт alembic из contrib/ast-db-manage вместе со всей
-- realtime-схемой Asterisk. На инсталляциях FreePBX, где realtime никогда
-- не использовался, таблицы может не быть — тогда применяется этот файл:
--
--     mysql asterisk < sql/03-ps-contacts.sql
--
-- Схема соответствует Asterisk 18–21. Набор колонок между мажорными
-- версиями отличается, поэтому если Asterisk новее — лучше создать таблицу
-- штатным способом:
--
--     cd /usr/src/asterisk*/contrib/ast-db-manage
--     alembic -c config.ini.sample upgrade head
--
-- Колонка reg_server — ключевая для кластера: в неё res_pjsip записывает
-- systemname узла, на котором зарегистрировался телефон. По ней диалплан
-- узнаёт, на какую площадку вести вызов.

CREATE TABLE IF NOT EXISTS ps_contacts (
  id                      VARCHAR(255) NOT NULL,
  uri                     VARCHAR(511) DEFAULT NULL,
  expiration_time         BIGINT       DEFAULT NULL,
  qualify_frequency       INT UNSIGNED DEFAULT NULL,
  outbound_proxy          VARCHAR(255) DEFAULT NULL,
  path                    TEXT         DEFAULT NULL,
  user_agent              VARCHAR(255) DEFAULT NULL,
  qualify_timeout         DECIMAL(6,3) DEFAULT NULL,
  reg_server              VARCHAR(255) DEFAULT NULL,
  authenticate_qualify    ENUM('0','1','off','on','false','true','no','yes') DEFAULT NULL,
  via_addr                VARCHAR(40)  DEFAULT NULL,
  via_port                INT UNSIGNED DEFAULT NULL,
  call_id                 VARCHAR(255) DEFAULT NULL,
  endpoint                VARCHAR(255) DEFAULT NULL,
  prune_on_boot           ENUM('0','1','off','on','false','true','no','yes') DEFAULT NULL,

  PRIMARY KEY (id),
  -- Индекс по endpoint: по нему диалплан ищет, где зарегистрирован абонент.
  KEY ps_contacts_endpoint (endpoint),
  -- Уникальность пары «контакт + узел»: один и тот же телефон может быть
  -- зарегистрирован на двух площадках одновременно (во время failover),
  -- и обе записи должны сосуществовать.
  UNIQUE KEY ps_contacts_id_reg_server (id, reg_server),
  KEY ps_contacts_qualifyfreq_exp (qualify_frequency, expiration_time)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
