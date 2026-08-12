<?php
/**
 * Provisioner — логика автопровижининга: проверка доступа, поиск телефона,
 * выдача учётных данных, рендер конфига под конкретного вендора.
 *
 * Отличия от черновика (provisioning-generate.php) по части безопасности:
 *
 *  1. Черновик отдавал SIP-пароль любому, кто знал MAC. MAC не секрет —
 *     он написан на корпусе телефона и виден в ARP-таблице. Здесь доступ
 *     ограничен четырьмя независимыми слоями: сеть, токен, окно
 *     провижининга, журнал.
 *  2. Черновик ходил в БД под asterisk_rt, у которого есть запись во всю
 *     схему. Здесь — отдельный пользователь только на чтение нужных таблиц.
 *  3. Черновик брал только password и подставлял auth_name = номер. Если в
 *     ps_auths другой username, телефон получал нерабочую пару. Здесь
 *     берётся именно ps_auths.username.
 */

declare(strict_types=1);

final class ProvisionDenied extends RuntimeException
{
    public function __construct(
        string $message,
        public readonly int $httpStatus,
        public readonly string $logResult
    ) {
        parent::__construct($message);
    }
}

final class Provisioner
{
    private PDO $pdo;

    public function __construct(private array $config)
    {
        $dsn = sprintf(
            'mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',
            $config['db_host'],
            $config['db_port'],
            $config['db_name']
        );
        $this->pdo = new PDO($dsn, $config['db_user'], $config['db_pass'], [
            PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES   => false,
        ]);
    }

    /**
     * Нормализует MAC к 12 hex-символам в нижнем регистре.
     *
     * Убираются только общепринятые разделители (:, -, ., пробел). Выкусывать
     * из строки вообще все не-hex символы нельзя: тогда «zz1565aabbccdd»
     * молча превратилось бы в валидный чужой MAC.
     */
    public static function normalizeMac(string $raw): ?string
    {
        $mac = strtolower(str_replace([':', '-', '.', ' '], '', trim($raw)));
        return preg_match('/^[0-9a-f]{12}$/', $mac) === 1 ? $mac : null;
    }

    /** Проверяет, что адрес входит в один из CIDR. */
    public static function ipInCidrList(string $ip, array $cidrs): bool
    {
        foreach ($cidrs as $cidr) {
            $cidr = trim($cidr);
            if ($cidr === '') {
                continue;
            }
            if (self::ipInCidr($ip, $cidr)) {
                return true;
            }
        }
        return false;
    }

    private static function ipInCidr(string $ip, string $cidr): bool
    {
        if (!str_contains($cidr, '/')) {
            return $ip === $cidr;
        }
        [$subnet, $bits] = explode('/', $cidr, 2);
        $bits = (int) $bits;

        $ipBin     = @inet_pton($ip);
        $subnetBin = @inet_pton($subnet);
        if ($ipBin === false || $subnetBin === false || strlen($ipBin) !== strlen($subnetBin)) {
            return false;
        }

        $bytes = intdiv($bits, 8);
        $rem   = $bits % 8;

        if ($bytes > 0 && substr($ipBin, 0, $bytes) !== substr($subnetBin, 0, $bytes)) {
            return false;
        }
        if ($rem === 0) {
            return true;
        }
        $mask = chr((0xFF << (8 - $rem)) & 0xFF);
        return (($ipBin[$bytes] & $mask) === ($subnetBin[$bytes] & $mask));
    }

    /** Токен для URL конкретного телефона. */
    public function macToken(string $mac): string
    {
        return substr(hash_hmac('sha256', $mac, $this->config['hmac_secret']), 0, 16);
    }

    /**
     * Слои проверки доступа. Порядок от дешёвого к дорогому.
     *
     * @throws ProvisionDenied
     */
    public function authorize(string $mac, string $srcIp, ?string $token): array
    {
        // Слой 1: сеть. Провижининг обслуживает только подсети телефонов.
        $allowed = $this->config['allowed_cidrs'];
        if ($allowed !== [] && !self::ipInCidrList($srcIp, $allowed)) {
            throw new ProvisionDenied('source network not allowed', 403, 'denied_network');
        }

        // Слой 2: токен. Либо общий (в DHCP option 66), либо HMAC от MAC.
        if ($this->config['require_token']) {
            $static = (string) $this->config['static_token'];
            $expected = $this->macToken($mac);
            $ok = false;
            if ($static !== '' && $token !== null && hash_equals($static, $token)) {
                $ok = true;
            }
            if ($token !== null && hash_equals($expected, $token)) {
                $ok = true;
            }
            if (!$ok) {
                throw new ProvisionDenied('invalid or missing token', 403, 'denied_token');
            }
        }

        // Слой 3: телефон должен быть заведён.
        $stmt = $this->pdo->prepare(
            'SELECT mac, extension, vendor, model, primary_server, backup_server,
                    home_node, label, timezone, provision_open_until, always_allow,
                    provision_count
               FROM phone_provision
              WHERE mac = :mac'
        );
        $stmt->execute(['mac' => $mac]);
        $phone = $stmt->fetch();
        if ($phone === false) {
            throw new ProvisionDenied('MAC not registered', 404, 'unknown_mac');
        }

        // Слой 4: окно провижининга. Пароль отдаётся, только когда
        // администратор открыл окно (phonectl.php arm) либо телефон помечен
        // always_allow. Знание MAC само по себе доступа не даёт.
        if ((int) $phone['always_allow'] !== 1) {
            $until = $phone['provision_open_until'];
            if ($until === null || strtotime((string) $until) < time()) {
                throw new ProvisionDenied(
                    'provisioning window is closed',
                    403,
                    'window_closed'
                );
            }
        }

        return $phone;
    }

    /**
     * Учётные данные SIP из realtime-таблицы ps_auths.
     * Берём и username, и password: в FreePBX auth username не обязан
     * совпадать с номером добавочного.
     */
    public function credentials(string $extension): array
    {
        $stmt = $this->pdo->prepare(
            'SELECT username, password FROM ps_auths WHERE id = :id LIMIT 1'
        );
        $stmt->execute(['id' => $extension]);
        $auth = $stmt->fetch();

        if ($auth === false) {
            // Запасной вариант: FreePBX иногда именует auth как "<ext>-auth".
            $stmt->execute(['id' => $extension . '-auth']);
            $auth = $stmt->fetch();
        }

        if ($auth === false) {
            throw new ProvisionDenied(
                "extension {$extension} has no auth record",
                404,
                'no_auth'
            );
        }
        if (($auth['password'] ?? '') === '' || $auth['password'] === null) {
            // auth_type=userpass обязателен: при md5-хешах отдать телефону
            // нечего, а молча выдать пустой пароль — хуже, чем отказать.
            throw new ProvisionDenied(
                "extension {$extension} has empty password (auth_type != userpass?)",
                409,
                'empty_password'
            );
        }

        return [
            'username' => (string) ($auth['username'] ?: $extension),
            'password' => (string) $auth['password'],
        ];
    }

    /** Рендерит конфиг под вендора. */
    public function render(array $phone, array $creds): array
    {
        $vendor = strtolower((string) $phone['vendor']);
        $tplDir = $this->config['template_dir'];

        $map = [
            'yealink'     => ['yealink.cfg.php', 'text/plain'],
            'fanvil'      => ['fanvil.cfg.php', 'text/plain'],
            'grandstream' => ['grandstream.xml.php', 'text/xml'],
        ];
        if (!isset($map[$vendor])) {
            throw new ProvisionDenied("unsupported vendor '{$vendor}'", 400, 'bad_vendor');
        }

        [$file, $mime] = $map[$vendor];
        $path = $tplDir . '/' . $file;
        if (!is_readable($path)) {
            throw new ProvisionDenied("template {$file} missing", 500, 'no_template');
        }

        // Переменные, доступные шаблону.
        $mac       = (string) $phone['mac'];
        $extension = (string) $phone['extension'];
        $label     = (string) ($phone['label'] ?: $extension);
        $primary   = (string) $phone['primary_server'];
        $backup    = (string) ($phone['backup_server'] ?? '');
        $timezone  = (string) $phone['timezone'];
        $authUser  = $creds['username'];
        $secret    = $creds['password'];
        $sipPort   = (int) $this->config['sip_port'];
        // Интервал перерегистрации. Компромисс между скоростью failover и
        // нагрузкой на общую таблицу ps_contacts: каждая регистрация — это
        // запись, реплицируемая на все узлы кластера.
        $expires   = (int) $this->config['register_expires'];

        ob_start();
        include $path;
        $body = (string) ob_get_clean();

        return [$body, $mime];
    }

    public function markProvisioned(string $mac): void
    {
        try {
            $this->pdo->prepare(
                'UPDATE phone_provision
                    SET provisioned_at = NOW(), provision_count = provision_count + 1
                  WHERE mac = :mac'
            )->execute(['mac' => $mac]);
        } catch (PDOException) {
            // Счётчик — не повод не отдать телефону конфиг.
        }
    }

    public function log(?string $mac, string $srcIp, string $result, string $detail = ''): void
    {
        try {
            $this->pdo->prepare(
                'INSERT INTO provision_log (mac, src_ip, user_agent, result, detail)
                 VALUES (:mac, :ip, :ua, :res, :detail)'
            )->execute([
                'mac'    => $mac,
                'ip'     => $srcIp,
                'ua'     => substr((string) ($_SERVER['HTTP_USER_AGENT'] ?? ''), 0, 255),
                'res'    => $result,
                'detail' => substr($detail, 0, 255),
            ]);
        } catch (PDOException) {
            // Журнал не должен ломать выдачу конфига.
        }
    }
}
