<?php
/**
 * Шаблон конфигурации Grandstream (XML-формат, прошивки 1.0.7.x и новее).
 *
 * Важно: старые модели GXP серии 21xx принимают только бинарный
 * cfg<MAC>.cfg, собранный утилитой Grandstream, — XML они игнорируют.
 * Для них провижининг придётся делать через штатный конвертер вендора;
 * здесь поддержаны модели с XML-провижинингом.
 *
 * P-коды: P47 — Outbound Proxy, P2312 — Backup Outbound Proxy.
 * Резервирование у Grandstream строится именно на backup outbound proxy,
 * а не на втором аккаунте.
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

$x = static fn (string $v): string => htmlspecialchars($v, ENT_XML1 | ENT_QUOTES, 'UTF-8');
?>
<?= '<?xml version="1.0" encoding="UTF-8"?>' . "\n" ?>
<gs_provision version="1">
  <mac><?= $x($mac) ?></mac>
  <config version="1">
    <!-- Аккаунт 1 -->
    <P271>1</P271>                                  <!-- Account Active -->
    <P270><?= $x($label) ?></P270>                  <!-- Account Name -->
    <P47><?= $x($primary) ?></P47>                  <!-- SIP Server -->
    <P35><?= $x($extension) ?></P35>                <!-- SIP User ID -->
    <P36><?= $x($authUser) ?></P36>                 <!-- Auth ID -->
    <P34><?= $x($secret) ?></P34>                   <!-- Auth Password -->
    <P3><?= $x($label) ?></P3>                      <!-- Display Name -->
    <P32><?= (int) ($expires / 60) ?: 1 ?></P32>    <!-- Register Expiration, мин -->
<?php if ($backup !== ''): ?>
    <P2312><?= $x($backup) ?></P2312>               <!-- Backup Outbound Proxy -->
    <P2333>1</P2333>                                <!-- Failback на основной -->
    <P2334>60</P2334>                               <!-- Интервал failback, сек -->
<?php endif; ?>
    <P52>3</P52>                                    <!-- NTP: DHCP -->
    <P64><?= $x($timezone) ?></P64>                 <!-- Часовой пояс -->
    <P1403>1</P1403>                                <!-- DTMF RFC2833 -->
    <P183>0</P183>                                  <!-- SRTP выключен -->
  </config>
</gs_provision>
