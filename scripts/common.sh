# Общие функции сборки. Подключается из build.sh и make-release.sh.

strip_ansi() { sed -E $'s/\x1b\\[[0-9;]*m//g'; }

show_errors() {
  strip_ansi < .build.log | grep -E "\.swift:[0-9]+:[0-9]+: error:" | sed "s|.*/Sources/||" | sort -u | head -20 | sed 's/^/[Ошибка] /'
  echo "[Сборка упала] полный лог: $PWD/.build.log"
}

# Сертификат для подписи: Volna Dev, иначе старый YaNotch Dev, иначе ad-hoc.
# Релизы подписывать ВСЕГДА одним и тем же сертификатом — иначе у пользователей слетит Универсальный доступ.
sign_identity() {
  local ids; ids=$(security find-identity -v -p codesigning 2>/dev/null)
  for n in "Volna Dev" "YaNotch Dev"; do
    echo "$ids" | grep -q "\"$n\"" && { echo "$n"; return; }
  done
  echo "-"
}

# assemble_app <бинарник> <куда положить Volna.app>
assemble_app() {
  local bin="$1" app="$2/Volna.app" id
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$bin" "$app/Contents/MacOS/Volna"
  cp Info.plist "$app/Contents/"
  id=$(sign_identity)
  codesign --force -s "$id" "$app" >/dev/null 2>&1
  echo "[Подпись] $([ "$id" = "-" ] && echo "ad-hoc — доступы сбросятся после пересборки" || echo "$id")"
}

# Текст релиза: раздел версии из CHANGELOG.md + блок установки одной командой.
# Окно обновления в приложении обрезает всё после «---».
release_notes() {
  local ver="$1" repo="$2" body
  body=$(awk -v v="$ver" '$0 ~ "^## \\[?"v"\\]?" {f=1; next} /^## / && f {exit} f' CHANGELOG.md | sed -e '/./,$!d')
  [ -n "$body" ] || return 1
  printf '%s\n\n---\n**Установка и обновление одной командой:**\n```bash\ncurl -fsSL https://raw.githubusercontent.com/%s/main/install.sh | bash\n```\n' "$body" "$repo"
}
