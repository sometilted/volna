#!/bin/bash
# Один раз на каждом маке: самоподписанный сертификат "Volna Dev" для стабильной подписи сборок.
# Нужен, чтобы разрешение «Универсальный доступ» не слетало после каждой пересборки.
# Спросит пароль от связки ключей (доверие сертификату для подписи кода).
set -e
NAME="Volna Dev"
if security find-identity -v -p codesigning | grep -qE "\"(Volna Dev|YaNotch Dev)\""; then echo "[Есть] сертификат для подписи уже есть"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/c.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/k.pem" -out "$T/c.pem" -days 3650 -config "$T/c.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -out "$T/c.p12" -passout pass:yn -name "$NAME"
security import "$T/c.p12" -k ~/Library/Keychains/login.keychain-db -P yn -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k ~/Library/Keychains/login.keychain-db "$T/c.pem"
security find-identity -v -p codesigning | grep -q "$NAME" && echo "[Создан] $NAME" || echo "[Ошибка] сертификат не виден для codesign"
