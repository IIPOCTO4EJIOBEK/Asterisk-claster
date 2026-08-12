#!/bin/bash
#
# run-all.sh — все тесты репозитория. БД и Asterisk не требуются.
#
#   ./tests/run-all.sh
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || { echo "Не удалось перейти в $REPO_ROOT"; exit 1; }

RC=0
run() {
  local name="$1"; shift
  printf '\n\033[1m=== %s ===\033[0m\n' "$name"
  if "$@"; then
    return 0
  fi
  RC=1
}

run "Статические проверки" ./scripts/lint.sh
run "Рендер конфигураций и утилиты" ./tests/test-render.sh
run "Парсер конфигов PJSIP" python3 tests/test-parser.py
run "Провижининг" php tests/test-provisioning.php

printf '\n'
if [ "$RC" -eq 0 ]; then
  echo "Все тесты пройдены."
else
  echo "Есть провалившиеся тесты — см. выше."
fi
exit "$RC"
