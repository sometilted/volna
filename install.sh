#!/bin/bash
# Установка Volna: curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/main/install.sh | bash
# Кладёт Volna.app в /Applications и запускает. Ничего не ставит в автозапуск.
set -e
REPO="sometilted/volna"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -oE '"browser_download_url": *"[^"]+\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
[ -n "$URL" ] || { echo "[Ошибка] не нашёл релиз в $REPO"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "[Качаю] $URL"
curl -fsSL "$URL" -o "$T/volna.zip"
ditto -x -k "$T/volna.zip" "$T"
pkill -x Volna 2>/dev/null || true
rm -rf /Applications/Volna.app
mv "$T/Volna.app" /Applications/
open /Applications/Volna.app
echo "[Готово] Volna в «Программах» и запущена — наведи мышь на нотч"
