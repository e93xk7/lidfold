#!/bin/sh
# 把 LidFoldApp 包成 LidFold.app 並簽章。
#
# 螢幕錄製（TCC）權限是綁在簽章上的，所以一定要用固定的憑證簽，
# 否則每次 build 權限都會掉（白皮書 5.5、風險 6）。
# 憑證用 scripts/make_cert.sh 建，只建一次。
#
#   scripts/build_app.sh            debug build
#   scripts/build_app.sh release    release build
set -e
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/LidFold.app"
IDENTITY="LidFold Dev"

# 一定要先把跑著的那份殺掉再覆蓋。
# 在行程跑著的時候換掉 .app 的內容，macOS 會判定「程式碼身分已變」，
# 當場撤銷螢幕錄製權限（實測過，錯誤是 SCStreamError -3801 TCC denied）。
pkill -f "LidFold.app/Contents/MacOS/LidFold" 2>/dev/null && sleep 1 || true

swift build -c "$CONFIG"
BIN=".build/$CONFIG/LidFoldApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LidFold"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LidFold</string>
    <key>CFBundleDisplayName</key><string>LidFold</string>
    <key>CFBundleIdentifier</key><string>local.lidfold</string>
    <key>CFBundleExecutable</key><string>LidFold</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3</string>
    <key>CFBundleVersion</key><string>3</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- 選單列常駐，不進 Dock -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" --timestamp=none \
        --options runtime --identifier local.lidfold "$APP"
    echo "已用 $IDENTITY 簽章 → $APP"
else
    codesign --force --sign - --identifier local.lidfold "$APP"
    echo "⚠️  找不到憑證 $IDENTITY，用 ad-hoc 簽章。"
    echo "    每次 build 簽章都會變，螢幕錄製權限會一直掉。"
    echo "    先跑一次 scripts/make_cert.sh 就不會了。"
fi

codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Authority" || true
