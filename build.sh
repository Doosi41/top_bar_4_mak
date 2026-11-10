#!/bin/zsh
# Собирает Topbar.app (отдельное приложение: права «Универсальный доступ» и «Запись экрана» выдаются ему самому).
set -e
cd "$(dirname "$0")"
APP=Topbar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
clang++ -std=c++17 -fobjc-arc -Wall -framework Cocoa -framework QuartzCore -framework ScreenCaptureKit \
    main.mm Animations.mm -o "$APP/Contents/MacOS/Topbar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Topbar</string>
    <key>CFBundleIdentifier</key><string>com.a1tvv.topbar</string>
    <key>CFBundleExecutable</key><string>Topbar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSUIElement</key><true/>
    <key>NSScreenCaptureUsageDescription</key><string>Снимок окна для анимации сворачивания.</string>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Готово: $APP"
