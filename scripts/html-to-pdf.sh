#!/usr/bin/env bash
# Печатает HTML-страницу в PDF headless-браузером.
#
# Внешних сервисов не нужно: используется Chromium, который уже стоит в
# окружении вместе с Playwright. Стили печати (@media print) страница
# определяет сама — здесь только запуск.
#
#   ./scripts/html-to-pdf.sh docs/plan/rollout.html out/rollout.pdf
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { printf '[x] %s\n' "$*" >&2; exit 1; }

[ "$#" -eq 2 ] || die "нужно два аргумента: <входной .html> <выходной .pdf>"

SRC="$1"
DST="$2"
[ -f "$SRC" ] || die "файл не найден: $SRC"

# Chromium от Playwright: сначала полный, потом headless shell.
CHROME=""
for c in "${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"/chromium-*/chrome-linux/chrome \
         "${PLAYWRIGHT_BROWSERS_PATH:-/opt/pw-browsers}"/chromium_headless_shell-*/chrome-linux/headless_shell; do
  [ -x "$c" ] && { CHROME="$c"; break; }
done
[ -n "$CHROME" ] || CHROME="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"
[ -n "$CHROME" ] || die "Chromium не найден: ни в \$PLAYWRIGHT_BROWSERS_PATH, ни в PATH"

SRC_ABS="$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")"
mkdir -p "$(dirname "$DST")"
DST_ABS="$(cd "$(dirname "$DST")" && pwd)/$(basename "$DST")"

PROFILE="$(mktemp -d)"
trap 'rm -rf "$PROFILE"' EXIT

# preferredColorScheme=1 — светлая тема: тёмный фон в PDF не нужен.
"$CHROME" \
  --headless \
  --no-sandbox \
  --disable-gpu \
  --user-data-dir="$PROFILE" \
  --blink-settings=preferredColorScheme=1 \
  --no-pdf-header-footer \
  --print-to-pdf-no-header \
  --generate-pdf-document-outline \
  --virtual-time-budget=8000 \
  --print-to-pdf="$DST_ABS" \
  "file://$SRC_ABS" 2>/dev/null || die "Chromium не смог напечатать $SRC"

[ -s "$DST_ABS" ] || die "PDF пустой: $DST_ABS"
printf '[ok] %s -> %s (%s)\n' "$SRC" "$DST" "$(du -h "$DST_ABS" | cut -f1)"
