<?php
/**
 * index.php — точка входа сервера автопровижининга.
 *
 * Поддерживаемые URL (nginx приводит их к одному виду):
 *   /prov/001565aabbcc.cfg?t=<token>     — Yealink ($MAC в шаблоне URL)
 *   /prov/001565aabbcc.xml?t=<token>     — Grandstream
 *   /index.php?mac=001565aabbcc&t=<token>
 *
 * Конфигурация читается из /etc/asterisk-cluster/provisioning.php,
 * который создаётся install-provisioning.sh и содержит пароль БД.
 */

declare(strict_types=1);

$configFile = getenv('PROV_CONFIG') ?: '/etc/asterisk-cluster/provisioning.php';
if (!is_readable($configFile)) {
    http_response_code(500);
    header('Content-Type: text/plain; charset=utf-8');
    exit("# provisioning is not configured\n");
}
$config = require $configFile;

require_once __DIR__ . '/../src/Provisioner.php';

header('Content-Type: text/plain; charset=utf-8');
// Конфиг телефона содержит пароль — он не должен оседать в кэшах.
header('Cache-Control: no-store, no-cache, must-revalidate, private');
header('Pragma: no-cache');
header('X-Content-Type-Options: nosniff');

$srcIp = (string) ($_SERVER['REMOTE_ADDR'] ?? '0.0.0.0');

// MAC может прийти и из пути, и из query. Форма пути зависит от вендора:
// Yealink просит <MAC>.cfg, Fanvil — <mac>.cfg, Grandstream — cfg<MAC>.xml.
$rawMac = (string) ($_GET['mac'] ?? '');
if ($rawMac === '') {
    $path = parse_url((string) ($_SERVER['REQUEST_URI'] ?? ''), PHP_URL_PATH) ?: '';
    if (preg_match('~/(?:cfg)?([0-9a-fA-F]{12})\.(?:cfg|xml|txt)$~', $path, $m)) {
        $rawMac = $m[1];
    }
}

$token = isset($_GET['t']) ? (string) $_GET['t'] : null;
$mac   = Provisioner::normalizeMac($rawMac);

try {
    $prov = new Provisioner($config);
} catch (PDOException $e) {
    http_response_code(500);
    error_log('provisioning: DB connection failed: ' . $e->getMessage());
    exit("# provisioning backend unavailable\n");
}

if ($mac === null) {
    http_response_code(400);
    $prov->log(null, $srcIp, 'bad_mac', substr($rawMac, 0, 64));
    exit("# invalid or missing MAC address\n");
}

try {
    $phone = $prov->authorize($mac, $srcIp, $token);
    $creds = $prov->credentials((string) $phone['extension']);
    [$body, $mime] = $prov->render($phone, $creds);
} catch (ProvisionDenied $e) {
    http_response_code($e->httpStatus);
    $prov->log($mac, $srcIp, $e->logResult, $e->getMessage());
    // Наружу — только факт отказа. Черновик в ответе 404 подсказывал
    // готовый INSERT со структурой таблицы; здесь подробности идут в журнал.
    exit("# provisioning refused\n");
} catch (Throwable $e) {
    http_response_code(500);
    error_log('provisioning: ' . $e->getMessage());
    $prov->log($mac, $srcIp, 'error', $e->getMessage());
    exit("# internal error\n");
}

header('Content-Type: ' . $mime . '; charset=utf-8');
$prov->markProvisioned($mac);
$prov->log($mac, $srcIp, 'ok', (string) $phone['extension']);
echo $body;
