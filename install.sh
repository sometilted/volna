#!/bin/bash
# Установка и обновление Volna одной командой:
#   curl -fsSL https://raw.githubusercontent.com/sometilted/volna/main/install.sh | bash
# Кладёт Volna.app в /Applications и запускает. Старую YaNotch (прежнее имя) закрывает и удаляет —
# вход и настройки Volna заберёт из неё сама. Ничего не ставит в автозапуск.
set -e
REPO="sometilted/volna"
URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -oE '"browser_download_url": *"[^"]+\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
[ -n "$URL" ] || { echo "[Ошибка] не нашёл релиз в $REPO"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "[Качаю] $URL"
curl -fsSL "$URL" -o "$T/volna.zip"
ditto -x -k "$T/volna.zip" "$T"
[ -d "$T/Volna.app" ] || { echo "[Ошибка] в архиве нет Volna.app"; exit 1; }

if pgrep -x YaNotch >/dev/null || [ -d /Applications/YaNotch.app ] || [ -d "$HOME/Applications/YaNotch.app" ]; then
  pkill -x YaNotch 2>/dev/null || true
  rm -rf /Applications/YaNotch.app "$HOME/Applications/YaNotch.app"
  echo "[Удалена] старая YaNotch — вход и настройки Volna перенесёт сама"
fi

pkill -x Volna 2>/dev/null || true
sleep 0.5
rm -rf /Applications/Volna.app
mv "$T/Volna.app" /Applications/
open /Applications/Volna.app
echo "[Готово] Volna $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/Volna.app/Contents/Info.plist) в «Программах» и запущена — наведи мышь на нотч"
