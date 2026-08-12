<?php
/**
 * Шаблон конфигурации Fanvil (формат <<VOIP CONFIG FILE>>).
 *
 * У Fanvil резервный сервер задаётся вторым блоком SIP-сервера внутри той же
 * линии (Backup Proxy), а не отдельным аккаунтом — иначе телефон покажет две
 * независимые регистрации вместо failover.
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

$esc = static fn (string $v): string => str_replace(["\r", "\n"], '', $v);
?>
<<VOIP CONFIG FILE>>Version:2.0000000000

<SIP CONFIG MODULE>
SIP1 Phone Number :<?= $esc($extension) ?>

SIP1 Display Name :<?= $esc($label) ?>

SIP1 Register Addr :<?= $esc($primary) ?>

SIP1 Register Port :<?= (int) $sipPort ?>

SIP1 Register User :<?= $esc($authUser) ?>

SIP1 Register Pswd :<?= $esc($secret) ?>

SIP1 Register TTL :<?= (int) $expires ?>

SIP1 Enable Reg :1
<?php if ($backup !== ''): ?>
SIP1 Backup Addr :<?= $esc($backup) ?>

SIP1 Backup Port :<?= (int) $sipPort ?>

SIP1 Enable Failback :1
SIP1 Failback Interval :60
<?php endif; ?>
SIP1 Signal Encrypt :0
SIP1 Media Encrypt :0
SIP1 DTMF Mode :1
SIP1 Enable Strict Proxy :1
SIP1 Enable Rport :1
</SIP CONFIG MODULE>

<AUTOUPDATE CONFIG MODULE>
Auto Update Mode :1
Update Interval :1440
</AUTOUPDATE CONFIG MODULE>

<TIME CONFIG MODULE>
Time Zone :<?= $esc($timezone) ?>

Enable DHCP Time :0
</TIME CONFIG MODULE>

<<END OF FILE>>
