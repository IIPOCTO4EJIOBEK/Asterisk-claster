#!/usr/bin/env bash
set -euo pipefail

APPLY=0
FORCE_ACTIVE_FAX_ROUTES=0
BACKUP_ROOT="${BACKUP_ROOT:-/root/pbx-fix-backups}"
AMPWEBROOT="${AMPWEBROOT:-/var/www/html}"
MYSQL_DB="${MYSQL_DB:-asterisk}"
FWCONSOLE="${FWCONSOLE:-/usr/sbin/fwconsole}"
PM2CLI="${PM2CLI:-/var/www/html/admin/modules/pm2/node/node_modules/.bin/pm2}"

CORE_DIR="$AMPWEBROOT/admin/modules/core"
FASTAGI_FILE="$CORE_DIR/node/fastagi-server.js"
CORE_SIG_FILE="$CORE_DIR/module.sig"
CORE_XML_FILE="$CORE_DIR/module.xml"

usage() {
  cat <<'EOF'
Usage:
  freepbx-live-fixes.sh core-fastagi [--apply] [--backup-root=/path]
  freepbx-live-fixes.sh fax-invalid-email [--apply] [--force-active-routes] [--backup-root=/path]
  freepbx-live-fixes.sh all [--apply] [--backup-root=/path]

Without --apply the script only prints current state and the intended action.

Fixes:
  core-fastagi       Restore the official FreePBX Core fastagi-server.js,
                     keep FastAGI bound on 127.0.0.1 with Node 20, refresh
                     the Core signature cache, and clear stale FW_TAMPERED.
  fax-invalid-email  Disable Receive Fax only for User Manager users that have
                     no email address, then clear the invalid_email notice.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_root() {
  local uid
  uid="$(id -u)"
  [ "$uid" = "0" ] || die "run this script as root on the FreePBX node"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_common_commands() {
  need_cmd awk
  need_cmd curl
  need_cmd grep
  need_cmd mysql
  need_cmd mysqldump
  need_cmd node
  need_cmd php
  need_cmd sha256sum
  need_cmd ss
  need_cmd su
  need_cmd timeout
  [ -x "$FWCONSOLE" ] || die "fwconsole not found or not executable: $FWCONSOLE"
  [ -x "$PM2CLI" ] || die "pm2 cli not found or not executable: $PM2CLI"
}

timestamp() {
  date +%Y%m%d-%H%M%S
}

backup_dir() {
  local suffix="$1"
  local dir="$BACKUP_ROOT/$(timestamp)-$suffix"
  mkdir -p "$dir"
  echo "$dir"
}

mysql_scalar() {
  mysql "$MYSQL_DB" -NBe "$1"
}

core_version() {
  awk -F'[<>]' '/<version>/ { print $3; exit }' "$CORE_XML_FILE"
}

expected_core_fastagi_hash() {
  awk -F' = ' '$1 == "node/fastagi-server.js" { print $2; exit }' "$CORE_SIG_FILE"
}

actual_fastagi_hash() {
  sha256sum "$FASTAGI_FILE" | awk '{ print $1 }'
}

pm2_env_prefix='export HOME=/var/lib/asterisk PM2_HOME=/var/lib/asterisk/.pm2 PATH=/var/lib/asterisk/.node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

pm2_status() {
  su -s /bin/bash asterisk -c "$pm2_env_prefix; '$PM2CLI' status"
}

pm2_restart_core_fastagi_ipv4() {
  su -s /bin/bash asterisk -c "$pm2_env_prefix; '$PM2CLI' restart core-fastagi --node-args='--dns-result-order=ipv4first' --update-env"
}

pm2_restart_core_fastagi_plain() {
  su -s /bin/bash asterisk -c "$pm2_env_prefix; '$PM2CLI' restart core-fastagi"
}

pm2_save() {
  su -s /bin/bash asterisk -c "$pm2_env_prefix; '$PM2CLI' save"
}

update_core_signature_cache() {
  php -r 'include "/etc/freepbx.conf"; global $modulef; $m=$modulef->updateSignature("core"); echo json_encode($m).PHP_EOL; if (($m["status"] ?? 0) !== 129 || !empty($m["details"])) { exit(7); }'
}

verify_node_localhost_is_ipv4() {
  NODE_OPTIONS=--dns-result-order=ipv4first node -e '
const net = require("net");
const server = net.createServer(() => {});
server.listen(0, "localhost", () => {
  const addr = server.address();
  console.log(addr.address + ":" + addr.port);
  process.exit(addr.address === "127.0.0.1" ? 0 : 22);
});
server.on("error", (err) => {
  console.error(err.message);
  process.exit(21);
});
'
}

verify_fastagi_listener() {
  ss -lntp | grep -q '127[.]0[.]0[.]1:4573' || return 1
  timeout 2 bash -lc '</dev/tcp/127.0.0.1/4573'
}

rollback_core_fastagi() {
  local dir="$1"
  if [ -f "$dir/fastagi-server.js.before" ]; then
    echo "Rolling back $FASTAGI_FILE from $dir/fastagi-server.js.before" >&2
    install -o asterisk -g asterisk -m 0664 "$dir/fastagi-server.js.before" "$FASTAGI_FILE"
    pm2_restart_core_fastagi_plain || true
  fi
}

core_fastagi_state() {
  local version expected current
  version="$(core_version)"
  expected="$(expected_core_fastagi_hash)"
  current="$(actual_fastagi_hash)"

  echo "Core version: $version"
  echo "Expected fastagi-server.js hash: $expected"
  echo "Current fastagi-server.js hash:  $current"
  echo
  echo "FastAGI listener:"
  ss -lntp | grep ':4573' || true
  echo
  echo "PM2 status:"
  pm2_status || true
  echo
  echo "Current FreePBX notifications:"
  "$FWCONSOLE" notifications --list --no-ansi || true
}

core_fastagi_apply() {
  local dir version expected official_hash official_url
  dir="$(backup_dir core-fastagi)"
  version="$(core_version)"
  expected="$(expected_core_fastagi_hash)"
  official_url="https://raw.githubusercontent.com/FreePBX/core/release/${version}/node/fastagi-server.js"

  [ -n "$version" ] || die "cannot detect FreePBX Core version from $CORE_XML_FILE"
  [ -n "$expected" ] || die "cannot find node/fastagi-server.js hash in $CORE_SIG_FILE"

  echo "Backup directory: $dir"
  cp -a "$FASTAGI_FILE" "$dir/fastagi-server.js.before"
  [ -f /var/lib/asterisk/.pm2/dump.pm2 ] && cp -a /var/lib/asterisk/.pm2/dump.pm2 "$dir/dump.pm2.before"
  mysqldump "$MYSQL_DB" notifications modules > "$dir/asterisk_notifications_modules.sql"

  echo "Downloading official FreePBX Core file: $official_url"
  curl -fsSL "$official_url" -o "$dir/fastagi-server.js.official"
  official_hash="$(sha256sum "$dir/fastagi-server.js.official" | awk '{ print $1 }')"
  [ "$official_hash" = "$expected" ] || die "downloaded official file hash $official_hash does not match module.sig $expected"

  echo "Checking Node localhost resolution with ipv4first"
  verify_node_localhost_is_ipv4

  echo "Installing official fastagi-server.js"
  install -o asterisk -g asterisk -m 0664 "$dir/fastagi-server.js.official" "$FASTAGI_FILE"

  if ! pm2_restart_core_fastagi_ipv4; then
    rollback_core_fastagi "$dir"
    die "core-fastagi restart failed"
  fi

  sleep 4

  if [ "$(actual_fastagi_hash)" != "$expected" ]; then
    rollback_core_fastagi "$dir"
    die "installed fastagi-server.js hash does not match module.sig"
  fi

  if ! verify_fastagi_listener; then
    rollback_core_fastagi "$dir"
    die "core-fastagi is not reachable on 127.0.0.1:4573"
  fi

  pm2_save

  echo "Refreshing Core signature cache"
  update_core_signature_cache | tee "$dir/core-signature-after.json"

  "$FWCONSOLE" notifications --delete freepbx FW_TAMPERED --no-ansi >/dev/null 2>&1 || true
  "$FWCONSOLE" ma list --no-ansi > "$dir/fwconsole-ma-list-after.txt"
  "$FWCONSOLE" notifications --list --no-ansi > "$dir/notifications-after.txt"

  if grep -Eiq 'FW_TAMPERED|tampered|altered' "$dir/notifications-after.txt"; then
    die "tampered-files notification is still present; see $dir/notifications-after.txt"
  fi

  echo "OK: Core tamper warning cleared and core-fastagi is listening on 127.0.0.1:4573"
}

core_fastagi() {
  core_fastagi_state
  if [ "$APPLY" -eq 0 ]; then
    echo
    echo "Dry-run only. Re-run with --apply to repair Core fastagi-server.js and clear FW_TAMPERED."
    return 0
  fi
  core_fastagi_apply
}

fax_counts() {
  echo "Fax enabled users:"
  mysql_scalar "SELECT COUNT(*) FROM fax_users WHERE faxenabled='true';"
  echo "Fax enabled users without email:"
  mysql_scalar "SELECT COUNT(*) FROM fax_users f JOIN userman_users u ON u.id=f.user WHERE f.faxenabled='true' AND (u.email IS NULL OR TRIM(u.email)='');"
  echo "Incoming fax routes:"
  mysql_scalar "SELECT COUNT(*) FROM fax_incoming;"
}

fax_invalid_email_apply() {
  local dir incoming bad_after
  dir="$(backup_dir fax-invalid-email)"
  incoming="$(mysql_scalar "SELECT COUNT(*) FROM fax_incoming;")"

  echo "Backup directory: $dir"
  mysqldump "$MYSQL_DB" notifications fax_users fax_details fax_incoming userman_users > "$dir/asterisk_notifications_fax_userman.sql"

  if [ "$incoming" -gt 0 ] && [ "$FORCE_ACTIVE_FAX_ROUTES" -eq 0 ]; then
    die "incoming fax routes exist ($incoming). Add real fax emails first or use --force-active-routes intentionally."
  fi

  mysql "$MYSQL_DB" <<'SQL' | tee "$dir/fax-update.txt"
START TRANSACTION;
UPDATE fax_users f
JOIN userman_users u ON u.id = f.user
SET f.faxenabled = 'false'
WHERE f.faxenabled = 'true'
  AND (u.email IS NULL OR TRIM(u.email) = '');
SELECT ROW_COUNT() AS disabled_fax_users_without_email;
COMMIT;
SQL

  "$FWCONSOLE" notifications --delete fax invalid_email --no-ansi >/dev/null 2>&1 || true
  php -r 'include "/etc/freepbx.conf"; try { FreePBX::create()->Fax->get_destinations(); } catch (Throwable $e) { fwrite(STDERR, $e->getMessage().PHP_EOL); }' || true

  bad_after="$(mysql_scalar "SELECT COUNT(*) FROM fax_users f JOIN userman_users u ON u.id=f.user WHERE f.faxenabled='true' AND (u.email IS NULL OR TRIM(u.email)='');")"
  [ "$bad_after" = "0" ] || die "fax users without email are still enabled: $bad_after"

  "$FWCONSOLE" notifications --list --no-ansi > "$dir/notifications-after.txt"
  if grep -Eiq 'invalid_email|Invalid Email for Inbound Fax' "$dir/notifications-after.txt"; then
    die "fax invalid_email notification is still present; see $dir/notifications-after.txt"
  fi

  echo "OK: fax invalid_email notification cleared"
}

fax_invalid_email() {
  fax_counts
  echo
  echo "Current FreePBX notifications:"
  "$FWCONSOLE" notifications --list --no-ansi || true
  if [ "$APPLY" -eq 0 ]; then
    echo
    echo "Dry-run only. Re-run with --apply to disable Receive Fax for users without email."
    return 0
  fi
  fax_invalid_email_apply
}

main() {
  local command="${1:-}"
  [ -n "$command" ] || { usage; exit 2; }
  shift || true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --apply)
        APPLY=1
        ;;
      --backup-root=*)
        BACKUP_ROOT="${1#*=}"
        ;;
      --force-active-routes)
        FORCE_ACTIVE_FAX_ROUTES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
    shift
  done

  require_root
  require_common_commands

  case "$command" in
    core-fastagi)
      core_fastagi
      ;;
    fax-invalid-email)
      fax_invalid_email
      ;;
    all)
      core_fastagi
      echo
      fax_invalid_email
      ;;
    *)
      usage
      exit 2
      ;;
  esac
}

main "$@"
