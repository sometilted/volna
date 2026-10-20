#!/bin/bash
# Релиз: универсальная сборка → zip → подпись ed25519 → GitHub Release с текстом из CHANGELOG.md.
# Версия берётся из Info.plist. Ничего не ставит в автозапуск.
cd "$(dirname "$0")/.."
. scripts/common.sh
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
grep -q 'static let repo = "OWNER/' Sources/Volna/UpdateConfig.swift && { echo "[Ошибка] сначала: bash scripts/setup-release.sh owner/repo"; exit 1; }
NOTES=$(awk -v v="$VER" '$0 ~ "^## \\[?"v"\\]?" {f=1; next} /^## / && f {exit} f' CHANGELOG.md | sed -e '/./,$!d')
[ -n "$NOTES" ] || { echo "[Ошибка] в CHANGELOG.md нет раздела ## $VER"; exit 1; }
REPO=$(grep -oE 'static let repo = "[^"]+"' Sources/Volna/UpdateConfig.swift | cut -d'"' -f2)
NOTES="$NOTES"$'\n\n---\n'"**Установка и обновление одной командой:**"$'\n```bash\n'"curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | bash"$'\n```' 

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" > .build.log 2>&1 || { show_errors; exit 1; }
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path 2>/dev/null)/Volna"
[ -f "$BIN" ] || BIN=$(ls -t .build/apple/Products/Release/Volna .build/out/Products/Release/Volna 2>/dev/null | head -1)
[ -f "$BIN" ] || { echo "[Ошибка] не нашёл бинарник"; exit 1; }

rm -rf dist && mkdir -p dist
assemble_app "$BIN" dist
ZIP="dist/Volna-$VER.zip"
ditto -c -k --keepParent dist/Volna.app "$ZIP"
swift scripts/sign.swift sign "$ZIP" > "$ZIP.sig" || exit 1
swift scripts/sign.swift verify "$ZIP" "$ZIP.sig"
echo "[Архитектуры] $(lipo -archs dist/Volna.app/Contents/MacOS/Volna)"
echo "[Архив] $PWD/$ZIP ($(du -h "$ZIP" | cut -f1))"

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh release create "v$VER" "$ZIP" "$ZIP.sig" --title "Volna $VER" --notes "$NOTES" && echo "[Релиз] v$VER опубликован"
else
  echo "[gh нет или не залогинен] опубликуй вручную: тег v$VER, файлы $ZIP и $ZIP.sig, текст — раздел $VER из CHANGELOG.md"
fi
