#!/bin/sh
# 建一張本機自簽的 code signing 憑證，讓每次 build 的簽章都一樣，
# 螢幕錄製（TCC）權限才不會每次 build 都掉（白皮書 5.5、風險 6）。
#
# 只在這台機器、只給這個專案用。不對外、不發行。
# 跑一次就好；憑證存在 login keychain 裡。
set -e

NAME="LidFold Dev"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "憑證「$NAME」已存在，不重建。"
    security find-identity -v -p codesigning | grep "$NAME" || true
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 自簽憑證 + 私鑰。extendedKeyUsage=codeSigning 是 codesign 認得它的關鍵。
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$TMP/cert.p12" \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:

# 匯入 login keychain，並允許 codesign 使用（-T）。
security import "$TMP/cert.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "" -T /usr/bin/codesign -A

echo
echo "憑證已匯入。接下來要把它設為「永遠信任」—— 會跳一次要你輸入登入密碼："
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning
