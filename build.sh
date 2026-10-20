#!/bin/bash
# Локальная сборка Volna.app (только под этот мак). Ничего не ставит в автозапуск.
cd "$(dirname "$0")"
. scripts/common.sh
rm -f .build/release/Volna
swift build -c release > .build.log 2>&1 || { show_errors; exit 1; }
[ -f .build/release/Volna ] || { echo "[Ошибка] бинарник не собрался"; exit 1; }
assemble_app .build/release/Volna .
echo "[Собрано] $(date +%H:%M:%S) $PWD/Volna.app"
