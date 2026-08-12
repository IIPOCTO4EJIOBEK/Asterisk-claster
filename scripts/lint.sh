#!/bin/bash
#
# lint.sh — статические проверки репозитория. Запускается локально и в CI.
#
#   ./scripts/lint.sh
#
# Что проверяется:
#   - синтаксис bash-скриптов (bash -n) и, если установлен, shellcheck
#   - синтаксис PHP (php -l)
#   - синтаксис Python (py_compile)
#   - что в шаблонах не осталось "живых" паролей вида ChangeMe
#   - что config/cluster.env не закоммичен
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Без set -e неудачный cd молча оставил бы нас в чужом каталоге, и проверки
# прошли бы «успешно», ничего не проверив.
cd "$REPO_ROOT" || { echo "Не удалось перейти в $REPO_ROOT"; exit 1; }

RC=0
pass() { printf '  [ok]   %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; RC=1; }
skip() { printf '  [skip] %s\n' "$*"; }

echo "== bash =="
while IFS= read -r f; do
  if bash -n "$f" 2>/tmp/lint.$$; then
    pass "$f"
  else
    fail "$f"
    sed 's/^/         /' /tmp/lint.$$
  fi
done < <(find scripts tests -name "*.sh" -type f | sort)
rm -f /tmp/lint.$$

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  while IFS= read -r f; do
    if shellcheck -S warning -e SC1090,SC1091 "$f" >/tmp/sc.$$ 2>&1; then
      pass "$f"
    else
      fail "$f"
      sed 's/^/         /' /tmp/sc.$$
    fi
  done < <(find scripts tests -name "*.sh" -type f | sort)
  rm -f /tmp/sc.$$
else
  skip "shellcheck не установлен (apt install shellcheck)"
fi

echo "== php =="
if command -v php >/dev/null 2>&1; then
  while IFS= read -r f; do
    if php -l "$f" >/tmp/php.$$ 2>&1; then
      pass "$f"
    else
      fail "$f"
      sed 's/^/         /' /tmp/php.$$
    fi
  done < <(find provisioning tests -name "*.php" -type f | sort)
  rm -f /tmp/php.$$
else
  skip "php не установлен"
fi

echo "== python =="
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r f; do
    if python3 -m py_compile "$f" 2>/tmp/py.$$; then
      pass "$f"
    else
      fail "$f"
      sed 's/^/         /' /tmp/py.$$
    fi
  done < <(find scripts tests -name "*.py" -type f | sort)
  rm -f /tmp/py.$$
  find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
else
  skip "python3 не установлен"
fi

echo "== секреты =="
# Рабочих паролей по умолчанию в репозитории быть не должно: именно так
# ChangeMe_* из черновика уезжали в прод.
if grep -rn --include='*.sh' --include='*.php' --include='*.tpl' --include='*.py' \
     -E '(PASS|PASSWORD|SECRET)\s*=\s*["'"'"']?(ChangeMe|changeme|password|123456)' . >/tmp/sec.$$ 2>/dev/null; then
  fail "найдены пароли по умолчанию:"
  sed 's/^/         /' /tmp/sec.$$
else
  pass "паролей по умолчанию нет"
fi
rm -f /tmp/sec.$$

if [ -f config/cluster.env ] && git ls-files --error-unmatch config/cluster.env >/dev/null 2>&1; then
  fail "config/cluster.env закоммичен — в нём пароли, уберите из индекса"
else
  pass "config/cluster.env не в индексе"
fi

echo "== шаблоны =="
# Каждая переменная {{VAR}} должна где-то экспортироваться скриптами.
MISSING=""
while IFS= read -r var; do
  if ! grep -rqE "(^|[^A-Z_])${var}=" scripts/ config/cluster.env.example 2>/dev/null; then
    MISSING="$MISSING $var"
  fi
done < <(grep -rho '{{[A-Z_][A-Z0-9_]*}}' config/ | tr -d '{}' | sort -u)
if [ -n "$MISSING" ]; then
  fail "переменные шаблонов, которые никто не задаёт:$MISSING"
else
  pass "все переменные шаблонов задаются скриптами"
fi

echo
if [ "$RC" -eq 0 ]; then
  echo "Все проверки пройдены."
else
  echo "Есть замечания — см. выше."
fi
exit "$RC"
