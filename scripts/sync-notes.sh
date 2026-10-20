#!/bin/bash
# Переписать текст уже опубликованных релизов по CHANGELOG.md: bash scripts/sync-notes.sh 0.1.0 0.1.1
# Только правит описание на GitHub, файлы релиза не трогает.
cd "$(dirname "$0")/.."
. scripts/common.sh
REPO=$(grep -oE 'static let repo = "[^"]+"' Sources/Volna/UpdateConfig.swift | cut -d'"' -f2)
for VER in "$@"; do
  NOTES=$(release_notes "$VER" "$REPO") || { echo "[Пропуск] $VER — нет раздела в CHANGELOG.md"; continue; }
  gh release edit "v$VER" --notes "$NOTES" >/dev/null && echo "[Обновлён] v$VER"
done
