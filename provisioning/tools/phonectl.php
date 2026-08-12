<?php
/**
 * phonectl.php — управление телефонами в автопровижининге.
 *
 * Ставится как /usr/local/bin/phonectl.
 *
 *   phonectl add 00:15:65:aa:bb:cc 564 --vendor=yealink \
 *       --primary=10.4.3.6 --backup=10.10.10.11 --home=voronezh --label="Приёмная"
 *   phonectl arm 001565aabbcc --minutes=30   # открыть окно провижининга
 *   phonectl url 001565aabbcc                # URL с токеном для этого телефона
 *   phonectl list [--node=voronezh]
 *   phonectl log [--limit=50] [--mac=...]
 *   phonectl close 001565aabbcc              # закрыть окно досрочно
 *   phonectl rm 001565aabbcc
 *
 * Работает под пользователем с правом записи в phone_provision — то есть под
 * учёткой администратора БД, а не под prov_ro, которым ходит веб-скрипт.
 */

declare(strict_types=1);

require_once __DIR__ . '/../src/Provisioner.php';

$configFile = getenv('PROV_CONFIG') ?: '/etc/asterisk-cluster/provisioning.php';
if (!is_readable($configFile)) {
    fwrite(STDERR, "Нет файла конфигурации {$configFile}\n");
    exit(1);
}
$config = require $configFile;

// Для записи нужен привилегированный доступ: берём admin-учётку из конфига,
// если она задана, иначе — root через unix-сокет.
$dsn = sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
    $config['db_host'], $config['db_port'], $config['db_name']);
$adminUser = $config['admin_db_user'] ?? 'root';
$adminPass = $config['admin_db_pass'] ?? '';
if (($config['admin_db_socket'] ?? '') !== '') {
    $dsn = sprintf('mysql:unix_socket=%s;dbname=%s;charset=utf8mb4',
        $config['admin_db_socket'], $config['db_name']);
}

try {
    $pdo = new PDO($dsn, $adminUser, $adminPass, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        PDO::ATTR_EMULATE_PREPARES   => false,
    ]);
} catch (PDOException $e) {
    fwrite(STDERR, "Не удалось подключиться к БД: {$e->getMessage()}\n");
    exit(1);
}

$argvCopy = $argv;
array_shift($argvCopy);
$cmd = array_shift($argvCopy) ?? 'help';

/** Разбирает --key=value в массив. */
$opts = [];
$positional = [];
foreach ($argvCopy as $a) {
    if (str_starts_with($a, '--')) {
        $kv = substr($a, 2);
        [$k, $v] = array_pad(explode('=', $kv, 2), 2, '1');
        $opts[$k] = $v;
    } else {
        $positional[] = $a;
    }
}

function need(array $pos, int $i, string $what): string
{
    if (!isset($pos[$i])) {
        fwrite(STDERR, "Не хватает аргумента: {$what}\n");
        exit(1);
    }
    return $pos[$i];
}

function macOrDie(string $raw): string
{
    $mac = Provisioner::normalizeMac($raw);
    if ($mac === null) {
        fwrite(STDERR, "Некорректный MAC: {$raw}\n");
        exit(1);
    }
    return $mac;
}

switch ($cmd) {
    case 'add':
        $mac = macOrDie(need($positional, 0, 'MAC'));
        $ext = need($positional, 1, 'номер добавочного');
        $primary = $opts['primary'] ?? '';
        if ($primary === '') {
            fwrite(STDERR, "Обязателен --primary=<ip основного сервера>\n");
            exit(1);
        }
        $stmt = $pdo->prepare(
            'INSERT INTO phone_provision
                (mac, extension, vendor, model, primary_server, backup_server,
                 home_node, label, timezone, always_allow)
             VALUES (:mac, :ext, :vendor, :model, :primary, :backup,
                     :home, :label, :tz, :always)
             ON DUPLICATE KEY UPDATE
                extension = VALUES(extension), vendor = VALUES(vendor),
                model = VALUES(model), primary_server = VALUES(primary_server),
                backup_server = VALUES(backup_server), home_node = VALUES(home_node),
                label = VALUES(label), timezone = VALUES(timezone),
                always_allow = VALUES(always_allow)'
        );
        $stmt->execute([
            'mac'     => $mac,
            'ext'     => $ext,
            'vendor'  => strtolower($opts['vendor'] ?? 'yealink'),
            'model'   => $opts['model'] ?? null,
            'primary' => $primary,
            'backup'  => $opts['backup'] ?? null,
            'home'    => $opts['home'] ?? null,
            'label'   => $opts['label'] ?? null,
            'tz'      => $opts['timezone'] ?? '+3',
            'always'  => isset($opts['always-allow']) ? 1 : 0,
        ]);
        echo "Телефон {$mac} -> добавочный {$ext} сохранён.\n";
        echo "Откройте окно провижининга: phonectl arm {$mac} --minutes=30\n";
        break;

    case 'arm':
        $mac = macOrDie(need($positional, 0, 'MAC'));
        $minutes = (int) ($opts['minutes'] ?? 30);
        if ($minutes < 1 || $minutes > 1440) {
            fwrite(STDERR, "--minutes должно быть от 1 до 1440\n");
            exit(1);
        }
        $stmt = $pdo->prepare(
            'UPDATE phone_provision
                SET provision_open_until = DATE_ADD(NOW(), INTERVAL :m MINUTE)
              WHERE mac = :mac'
        );
        $stmt->execute(['m' => $minutes, 'mac' => $mac]);
        if ($stmt->rowCount() === 0) {
            fwrite(STDERR, "MAC {$mac} не найден. Сначала phonectl add.\n");
            exit(1);
        }
        echo "Окно провижининга для {$mac} открыто на {$minutes} мин.\n";
        // fall through к выводу URL
        // no break
    case 'url':
        $mac = macOrDie($positional[0] ?? '');
        $prov = new Provisioner($config);
        $token = $prov->macToken($mac);
        $host = $config['public_host'] ?? '<адрес-сервера>';
        $port = $config['public_port'] ?? 8443;
        $scheme = ($config['public_scheme'] ?? 'https');
        echo "URL для этого телефона:\n";
        echo "  {$scheme}://{$host}:{$port}/prov/{$mac}.cfg?t={$token}\n";
        if (($config['static_token'] ?? '') !== '') {
            echo "URL для DHCP option 66 (общий для всех телефонов):\n";
            echo "  {$scheme}://{$host}:{$port}/prov/\$MAC.cfg?t={$config['static_token']}\n";
        }
        break;

    case 'close':
        $mac = macOrDie(need($positional, 0, 'MAC'));
        $pdo->prepare('UPDATE phone_provision SET provision_open_until = NULL WHERE mac = :mac')
            ->execute(['mac' => $mac]);
        echo "Окно провижининга для {$mac} закрыто.\n";
        break;

    case 'list':
        $sql = 'SELECT mac, extension, vendor, primary_server, backup_server, home_node,
                       label, always_allow, provision_open_until, provisioned_at, provision_count
                  FROM phone_provision';
        $params = [];
        if (isset($opts['node'])) {
            $sql .= ' WHERE home_node = :node';
            $params['node'] = $opts['node'];
        }
        $sql .= ' ORDER BY home_node, extension';
        $stmt = $pdo->prepare($sql);
        $stmt->execute($params);
        printf("%-13s %-8s %-10s %-15s %-15s %-10s %s\n",
            'MAC', 'Номер', 'Вендор', 'Основной', 'Резервный', 'Площадка', 'Окно');
        foreach ($stmt as $r) {
            $window = (int) $r['always_allow'] === 1
                ? 'всегда'
                : ($r['provision_open_until'] !== null
                    && strtotime((string) $r['provision_open_until']) > time()
                        ? 'открыто до ' . $r['provision_open_until']
                        : 'закрыто');
            printf("%-13s %-8s %-10s %-15s %-15s %-10s %s\n",
                $r['mac'], $r['extension'], $r['vendor'], $r['primary_server'],
                (string) $r['backup_server'], (string) $r['home_node'], $window);
        }
        break;

    case 'log':
        $limit = min(500, max(1, (int) ($opts['limit'] ?? 50)));
        $sql = 'SELECT ts, mac, src_ip, result, detail FROM provision_log';
        $params = [];
        if (isset($opts['mac'])) {
            $sql .= ' WHERE mac = :mac';
            $params['mac'] = macOrDie($opts['mac']);
        }
        // LIMIT не биндится как параметр в prepared statement MySQL —
        // значение уже приведено к int выше.
        $sql .= ' ORDER BY id DESC LIMIT ' . $limit;
        $stmt = $pdo->prepare($sql);
        $stmt->execute($params);
        printf("%-20s %-13s %-16s %-16s %s\n", 'Время', 'MAC', 'IP', 'Результат', 'Детали');
        foreach ($stmt as $r) {
            printf("%-20s %-13s %-16s %-16s %s\n",
                $r['ts'], (string) $r['mac'], (string) $r['src_ip'],
                $r['result'], (string) $r['detail']);
        }
        break;

    case 'rm':
        $mac = macOrDie(need($positional, 0, 'MAC'));
        $pdo->prepare('DELETE FROM phone_provision WHERE mac = :mac')->execute(['mac' => $mac]);
        echo "Телефон {$mac} удалён.\n";
        break;

    default:
        $doc = file_get_contents(__FILE__);
        if ($doc !== false && preg_match('~/\*\*(.*?)\*/~s', $doc, $m)) {
            echo preg_replace('~^\s*\*~m', ' ', $m[1]), "\n";
        }
        break;
}
