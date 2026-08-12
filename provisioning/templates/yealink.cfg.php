<?php
/**
 * Шаблон конфигурации Yealink (прошивки V80+ / V84+).
 *
 * Ключевой момент — failover. Одного лишь sip_server.2.address, как было в
 * черновике, недостаточно: без явного включения режима резервирования и
 * настроек возврата телефон не переключится предсказуемо. Здесь заданы:
 *   - sip_server.1 / sip_server.2 (основной и резервный регистратор)
 *   - failback_mode и таймер возврата на основной сервер
 *   - интервалы перерегистрации и повторных попыток
 *
 * Доступные переменные: $mac $extension $label $authUser $secret
 *                       $primary $backup $sipPort $expires $timezone
 *
 * @var string $mac
 * @var string $extension
 * @var string $label
 * @var string $authUser
 * @var string $secret
 * @var string $primary
 * @var string $backup
 * @var int    $sipPort
 * @var int    $expires
 * @var string $timezone
 */

// Значения уходят в текстовый .cfg: переносы строк в них сломали бы формат.
$esc = static fn (string $v): string => str_replace(["\r", "\n"], '', $v);

$retryInterval = 10;              // через сколько секунд пробовать снова
$failbackTimer = 60;              // через сколько возвращаться на основной
?>
#!version:1.0.0.1
# Сгенерировано автоматически: MAC <?= $esc($mac) ?>, добавочный <?= $esc($extension) ?>

# Основной сервер: <?= $esc($primary) ?>, резервный: <?= $esc($backup ?: 'нет') ?>

# Не редактируйте вручную — файл выдаётся сервером провижининга.

account.1.enable = 1
account.1.label = <?= $esc($label) ?>

account.1.display_name = <?= $esc($extension) ?>

account.1.auth_name = <?= $esc($authUser) ?>

account.1.user_name = <?= $esc($extension) ?>

account.1.password = <?= $esc($secret) ?>


#--- основной регистратор ------------------------------------------------
account.1.sip_server.1.address = <?= $esc($primary) ?>

account.1.sip_server.1.port = <?= (int) $sipPort ?>

account.1.sip_server.1.expires = <?= (int) $expires ?>

account.1.sip_server.1.retry_counts = 3
<?php if ($backup !== ''): ?>

#--- резервный регистратор ------------------------------------------------
# Включается, когда основной не отвечает. failback_mode = 1 — вернуться на
# основной, как только он снова доступен (иначе телефон останется на резерве
# до перезагрузки, и площадка будет обслуживаться мастером без причины).
account.1.sip_server.2.address = <?= $esc($backup) ?>

account.1.sip_server.2.port = <?= (int) $sipPort ?>

account.1.sip_server.2.expires = <?= (int) $expires ?>

account.1.sip_server.2.retry_counts = 3
account.1.sip_server_type = 0
account.1.fallback.redundancy_type = 1
account.1.fallback.timeout = <?= (int) $failbackTimer ?>

account.1.failback_mode = 1
<?php endif; ?>

#--- поведение регистрации ------------------------------------------------
account.1.reregister_enable = 1
account.1.register_expire_mode = 0
account.1.retry_interval = <?= (int) $retryInterval ?>

account.1.subscribe_register = 0
account.1.sip_send_line = 1

#--- медиа и NAT ----------------------------------------------------------
account.1.nat.nat_traversal = 0
account.1.srtp_encryption = 0
account.1.dtmf.type = 2
account.1.codec.g722.enable = 1
account.1.codec.pcma.enable = 1
account.1.codec.pcmu.enable = 1

#--- общие настройки ------------------------------------------------------
local_time.time_zone = <?= $esc($timezone) ?>

local_time.summer_time = 0
local_time.dhcp_time = 0

# Перечитывать конфигурацию раз в сутки ночью. Пароль при этом будет отдан
# только если телефон помечен always_allow либо окно провижининга открыто.
auto_provision.mode = 1
auto_provision.repeat.enable = 1
auto_provision.repeat.minutes = 1440
