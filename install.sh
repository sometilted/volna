#!/bin/bash
# Установка и обновление Volna одной командой:
#   curl -fsSL https://raw.githubusercontent.com/sometilted/volna/main/install.sh | bash
# Админ — ставит в /Applications. Обычный пользователь — в ~/Applications (без пароля,
# и обновления потом тоже ставятся без пароля). Бета-версию под именем YaNotch удаляет,
# вход и настройки Volna переносит сама. Ничего не ставит в автозапуск.
set -e
REPO="sometilted/volna"

# удалить бандл; если не хватает прав — системное окно с логином и паролем администратора
rm_app() {
  local p="$1"
  [ -e "$p" ] || return 0
  rm -rf "$p" 2>/dev/null && return 0
  osascript -e "do shell script \"rm -rf '$p'\" with administrator privileges" >/dev/null 2>&1 && return 0
  echo "[Не удалось удалить] $p — удали вручную"
}

if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

URL=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
  | grep -oE '"browser_download_url": *"[^"]+\.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
[ -n "$URL" ] || { echo "[Ошибка] не нашёл релиз в $REPO"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
echo "[Качаю] $URL"
curl -fsSL "$URL" -o "$T/volna.zip"
ditto -x -k "$T/volna.zip" "$T"
[ -d "$T/Volna.app" ] || { echo "[Ошибка] в архиве нет Volna.app"; exit 1; }

# бета-версия (YaNotch) и копии Volna в другой папке приложений
pkill -x YaNotch 2>/dev/null || true
pkill -x Volna 2>/dev/null || true
sleep 0.5
for p in /Applications/YaNotch.app "$HOME/Applications/YaNotch.app"; do
  [ -e "$p" ] && { rm_app "$p"; echo "[Удалена] бета-версия: $p"; }
done
for p in /Applications/Volna.app "$HOME/Applications/Volna.app"; do
  [ "$p" = "$DEST/Volna.app" ] || rm_app "$p"
done

rm -rf "$DEST/Volna.app"
mv "$T/Volna.app" "$DEST/"
open "$DEST/Volna.app"
echo "[Готово] Volna $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Volna.app/Contents/Info.plist") → $DEST — наведи мышь на нотч"
