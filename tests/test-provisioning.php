<?php
/**
 * Тесты провижининга: контроль доступа и рендер шаблонов вендоров.
 *
 * Запуск:  php tests/test-provisioning.php
 * БД не требуется — проверяются чистые функции и шаблоны.
 */

declare(strict_types=1);

$root = dirname(__DIR__);
require_once $root . '/provisioning/src/Provisioner.php';

$failed = [];

function check(bool $cond, string $msg): void
{
    global $failed;
    if ($cond) {
        echo "  [ok]   {$msg}\n";
    } else {
        echo "  [FAIL] {$msg}\n";
        $failed[] = $msg;
    }
}

echo "== нормализация MAC ==\n";
check(Provisioner::normalizeMac('00:15:65:AA:BB:CC') === '001565aabbcc',
    'MAC с двоеточиями приводится к нижнему регистру');
check(Provisioner::normalizeMac('00-15-65-aa-bb-cc') === '001565aabbcc',
    'MAC с дефисами');
check(Provisioner::normalizeMac('0015.65aa.bbcc') === '001565aabbcc',
    'MAC с точками');
check(Provisioner::normalizeMac(' 001565AABBCC ') === '001565aabbcc',
    'пробелы по краям обрезаются');
check(Provisioner::normalizeMac('001565aabbcc') === '001565aabbcc',
    'MAC без разделителей');
check(Provisioner::normalizeMac('00-15-65-aa-bb') === null,
    'короткий MAC отвергается');
check(Provisioner::normalizeMac('') === null,
    'пустая строка отвергается');
// Выкусывание всех не-hex символов превратило бы это в валидный чужой MAC.
check(Provisioner::normalizeMac('zz1565aabbccdd') === null,
    'мусор не превращается молча в валидный MAC');
check(Provisioner::normalizeMac('001565aabbcc/../etc/passwd') === null,
    'попытка обхода пути отвергается');

echo "== проверка сети ==\n";
check(Provisioner::ipInCidrList('10.4.3.6', ['10.4.0.0/16']),
    'адрес внутри /16');
check(!Provisioner::ipInCidrList('10.5.3.6', ['10.4.0.0/16']),
    'адрес вне /16 отвергается');
check(Provisioner::ipInCidrList('192.168.1.55', ['10.0.0.0/8', '192.168.1.0/24']),
    'совпадение со вторым CIDR списка');
check(!Provisioner::ipInCidrList('192.168.2.55', ['192.168.1.0/24']),
    'соседняя /24 отвергается');
check(Provisioner::ipInCidrList('10.4.3.6', ['10.4.3.6']),
    'точное совпадение без маски');
check(Provisioner::ipInCidrList('10.1.2.3', ['0.0.0.0/0']),
    'нулевая маска пропускает всё');
check(!Provisioner::ipInCidrList('10.4.3.6', []),
    'пустой список никого не пропускает');
// Границы на невыровненной по байту маске — там чаще всего и ошибаются.
check(Provisioner::ipInCidrList('10.4.3.130', ['10.4.3.128/25']),
    'верхняя половина /25 входит');
check(!Provisioner::ipInCidrList('10.4.3.127', ['10.4.3.128/25']),
    'нижняя половина /25 не входит');
check(Provisioner::ipInCidrList('10.4.3.128', ['10.4.3.128/25']),
    'нижняя граница /25 включительно');
check(Provisioner::ipInCidrList('10.4.3.255', ['10.4.3.128/25']),
    'верхняя граница /25 включительно');
check(!Provisioner::ipInCidrList('not-an-ip', ['10.0.0.0/8']),
    'мусор вместо адреса отвергается');
check(!Provisioner::ipInCidrList('10.4.3.6', ['мусор/24']),
    'мусор вместо CIDR не пропускает');

echo "== рендер шаблонов вендоров ==\n";

// Пароль намеренно содержит символы, значимые и для XML (&, <), и для
// текстовых форматов (/, |): шаблон обязан либо экранировать их, либо
// передать как есть — но так, чтобы телефон получил исходное значение.
$vars = [
    'mac'       => '001565aabbcc',
    'extension' => '564',
    'label'     => 'Приёмная',
    'authUser'  => '564-auth',
    'secret'    => 'aB3&xY/z|9<q',
    'primary'   => '10.4.3.6',
    'backup'    => '10.10.10.11',
    'sipPort'   => 5060,
    'expires'   => 600,
    'timezone'  => '+3',
];

/** Рендерит шаблон с заданными переменными. */
function render(string $tpl, array $vars): string
{
    extract($vars);
    ob_start();
    include dirname(__DIR__) . '/provisioning/templates/' . $tpl;
    return (string) ob_get_clean();
}

// Текстовые форматы: значение попадает в конфиг как есть.
foreach (['yealink.cfg.php', 'fanvil.cfg.php'] as $tpl) {
    $out = render($tpl, $vars);
    check(str_contains($out, $vars['secret']), "{$tpl}: пароль передан без искажений");
    check(str_contains($out, $vars['primary']), "{$tpl}: основной сервер на месте");
    check(str_contains($out, $vars['backup']), "{$tpl}: резервный сервер на месте");
    check(str_contains($out, $vars['authUser']), "{$tpl}: auth-логин, а не номер добавочного");
    check(!str_contains($out, "\r"), "{$tpl}: без возвратов каретки");
}

// XML: значение экранируется, поэтому проверяем не подстроку, а то, что
// после разбора документа телефон получит исходный пароль.
$xml = render('grandstream.xml.php', $vars);
$doc = simplexml_load_string($xml);
check($doc !== false, 'grandstream.xml.php: документ разбирается как XML');
if ($doc !== false) {
    check((string) $doc->config->P34 === $vars['secret'],
        'grandstream.xml.php: пароль после разбора XML совпадает с исходным');
    check((string) $doc->config->P47 === $vars['primary'],
        'grandstream.xml.php: основной сервер');
    check((string) $doc->config->P2312 === $vars['backup'],
        'grandstream.xml.php: резервный outbound proxy');
    check((string) $doc->config->P36 === $vars['authUser'],
        'grandstream.xml.php: auth-логин');
}

echo "== поведение без резервного сервера ==\n";
$noBackup = array_merge($vars, ['backup' => '']);

$out = render('yealink.cfg.php', $noBackup);
check(!str_contains($out, 'sip_server.2'),
    'yealink: блок резерва отсутствует, если backup не задан');
check(str_contains($out, 'sip_server.1'),
    'yealink: основной сервер остаётся на месте');

$out = render('fanvil.cfg.php', $noBackup);
check(!str_contains($out, 'Backup Addr'),
    'fanvil: блок резерва отсутствует');

$xml = render('grandstream.xml.php', $noBackup);
check(simplexml_load_string($xml) !== false,
    'grandstream: без резерва документ остаётся валидным XML');
check(!str_contains($xml, 'P2312'),
    'grandstream: backup proxy отсутствует');

echo "== failover действительно включён ==\n";
// Одного второго адреса мало: без явного включения резервирования и
// failback телефон либо не переключится, либо не вернётся обратно.
$out = render('yealink.cfg.php', $vars);
check(str_contains($out, 'fallback.redundancy_type'),
    'yealink: режим резервирования включён, а не только второй адрес');
check(str_contains($out, 'failback_mode = 1'),
    'yealink: возврат на основной сервер включён');

$out = render('fanvil.cfg.php', $vars);
check(str_contains($out, 'Enable Failback :1'),
    'fanvil: возврат на основной сервер включён');

$xml = render('grandstream.xml.php', $vars);
check(str_contains($xml, '<P2333>1</P2333>'),
    'grandstream: возврат на основной сервер включён');

echo "\n";
if ($failed !== []) {
    echo 'Провалено проверок: ' . count($failed) . "\n";
    exit(1);
}
echo "Провижининг: все проверки пройдены.\n";
