#!/bin/bash
# Один раз перед первым релизом: ключ подписи обновлений + адрес репозитория в коде.
# Использование: bash scripts/setup-release.sh <owner>/<repo>
cd "$(dirname "$0")/.."
REPO="$1"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "[Ошибка] bash scripts/setup-release.sh owner/repo"; exit 1; }
PUB=$(swift scripts/sign.swift keygen | grep -oE '[A-Za-z0-9+/=]{40,}' | tail -1)
[ -n "$PUB" ] || { echo "[Ошибка] ключ не создался"; exit 1; }
sed -i '' -E "s|static let repo = \"[^\"]*\"|static let repo = \"$REPO\"|; s|static let publicKey = \"[^\"]*\"|static let publicKey = \"$PUB\"|" Sources/Volna/UpdateConfig.swift
sed -i '' -E "s|^REPO=.*|REPO=\"$REPO\"|" install.sh
sed -i '' -E "s|OWNER/volna|$REPO|g" README.md
echo "[Репозиторий] $REPO"
echo "[Публичный ключ] $PUB"
echo "[Приватный ключ] ~/.config/volna/release_ed25519 — НЕ в репозиторий, сохрани копию (без него обновления не подписать)"
