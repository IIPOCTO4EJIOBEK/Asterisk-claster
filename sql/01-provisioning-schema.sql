-- Схема автопровижининга.
-- Применяется на мастере: mysql asterisk < sql/01-provisioning-schema.sql
--
-- Все таблицы InnoDB с первичным ключом — иначе Galera реплицирует их
-- неэффективно или не реплицирует вовсе.

CREATE TABLE IF NOT EXISTS phone_provision (
  mac             VARCHAR(12)  NOT NULL,
  extension       VARCHAR(20)  NOT NULL,
  vendor          VARCHAR(20)  NOT NULL DEFAULT 'yealink',
  model           VARCHAR(40)  DEFAULT NULL,

  -- Куда телефон регистрируется. primary_server — своя площадка,
  -- backup_server — мастер (или соседняя площадка).
  primary_server  VARCHAR(64)  NOT NULL,
  backup_server   VARCHAR(64)  DEFAULT NULL,

  -- Домашний узел абонента: используется диалпланом, когда телефон
  -- нигде не зарегистрирован (голосовая почта и т.п.).
  home_node       VARCHAR(32)  DEFAULT NULL,

  label           VARCHAR(64)  DEFAULT NULL,
  timezone        VARCHAR(16)  NOT NULL DEFAULT '+3',

  -- Окно провижининга. Пароль SIP отдаётся ТОЛЬКО внутри этого окна.
  -- Открывается администратором на время развёртывания телефона:
  --   phonectl.php arm <mac> --minutes=30
  -- Так конфиг с паролем нельзя выкачать в произвольный момент, зная MAC.
  provision_open_until DATETIME DEFAULT NULL,

  -- Постоянно разрешённый провижининг (телефон перечитывает конфиг по
  -- расписанию). Удобно, но снижает защиту — ставьте осознанно.
  always_allow    TINYINT(1)   NOT NULL DEFAULT 0,

  provisioned_at  DATETIME     DEFAULT NULL,
  provision_count INT          NOT NULL DEFAULT 0,
  created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,

  PRIMARY KEY (mac),
  KEY idx_extension (extension),
  KEY idx_home_node (home_node)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Журнал обращений к провижинингу: кто, когда, с какого адреса и чем
-- закончилось. Нужен и для разбора инцидентов, и просто чтобы видеть,
-- что телефон реально забрал конфиг.
CREATE TABLE IF NOT EXISTS provision_log (
  id          BIGINT       NOT NULL AUTO_INCREMENT,
  ts          DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  mac         VARCHAR(12)  DEFAULT NULL,
  src_ip      VARCHAR(45)  DEFAULT NULL,
  user_agent  VARCHAR(255) DEFAULT NULL,
  result      VARCHAR(32)  NOT NULL,
  detail      VARCHAR(255) DEFAULT NULL,
  PRIMARY KEY (id),
  KEY idx_ts (ts),
  KEY idx_mac (mac),
  KEY idx_result (result)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Пример записи (замените MAC и адреса на свои):
--
-- INSERT INTO phone_provision
--   (mac, extension, vendor, primary_server, backup_server, home_node, label)
-- VALUES
--   ('001565aabbcc', '564', 'yealink', '10.4.3.6', '10.10.10.11', 'voronezh', 'Приёмная');
