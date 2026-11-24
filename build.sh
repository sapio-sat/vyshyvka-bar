#!/bin/bash
# VYSHYVKA BAR — сборка из исходников (нужны только Command Line Tools: xcode-select --install).
#   ./build.sh          → build/VYSHYVKA BAR.app (universal: Apple Silicon + Intel)
#   ./build.sh --dmg    → ещё и dist/VYSHYVKA-BAR-<версия>.dmg для раздачи
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(cat VERSION)"
SDK=$(xcrun --show-sdk-path)
APP="build/VYSHYVKA BAR.app"
rm -rf "$APP" build/obj; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$ARCH-apple-macos12.0" \
    -import-objc-header Sources/Bridge.h \
    -F "$SDK/System/Library/PrivateFrameworks" -framework DFRFoundation \
    -framework AppKit -framework QuartzCore -framework Carbon -framework IOKit -framework CoreAudio \
    -framework AudioToolbox -framework AVFoundation -framework Metal -framework ServiceManagement \
    Sources/*.swift -o "build/obj/VyshyvkaBar-$ARCH"
done
lipo -create build/obj/VyshyvkaBar-arm64 build/obj/VyshyvkaBar-x86_64 -output "$APP/Contents/MacOS/VyshyvkaBar"

# Иконка рисуется самим приложением (векторный тризуб), затем iconutil → .icns
ICON=build/obj/AppIcon.iconset; mkdir -p "$ICON"
for s in 16 32 128 256 512; do
  "$APP/Contents/MacOS/VyshyvkaBar" --icon "$ICON/icon_${s}x${s}.png" $s
  "$APP/Contents/MacOS/VyshyvkaBar" --icon "$ICON/icon_${s}x${s}@2x.png" $((s * 2))
done
iconutil -c icns "$ICON" -o "$APP/Contents/Resources/AppIcon.icns"
# Превью шпалер для вікна привітання (кадр тієї ж сцени, 600 px)
"$APP/Contents/MacOS/VyshyvkaBar" --wallpaper-frame build/obj/wp.png 6 >/dev/null
sips -Z 600 build/obj/wp.png --out "$APP/Contents/Resources/wallpaper-preview.png" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>ua.vyshyvka.bar</string>
  <key>CFBundleName</key><string>VYSHYVKA BAR</string>
  <key>CFBundleDisplayName</key><string>VYSHYVKA BAR</string>
  <key>CFBundleExecutable</key><string>VyshyvkaBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>VYSHYVKA BAR · MIT License</string>
</dict></plist>
PLIST

# Локальная постоянная подпись, если в связке ключей есть сертификат «VYSHYVKA BAR Local Signing»
# (разрешение «Универсальный доступ» тогда переживает пересборку). Иначе — ad-hoc.
ID=$(security find-identity -p codesigning 2>/dev/null | awk '/VYSHYVKA BAR Local Signing/ {print $2; exit}')
codesign --force --sign "${ID:--}" --identifier ua.vyshyvka.bar "$APP"
codesign --verify --strict "$APP"
echo "built: $APP ($(du -sh "$APP" | cut -f1)), $(lipo -archs "$APP/Contents/MacOS/VyshyvkaBar"), signed: ${ID:-ad-hoc}"

if [ "${1:-}" = "--dmg" ]; then
  mkdir -p dist
  STAGE=build/obj/dmg; rm -rf "$STAGE"; mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/VYSHYVKA BAR.app"
  ln -s /Applications "$STAGE/Applications"
  cp packaging/INSTALL.txt "$STAGE/Як встановити · How to install.txt"
  DMG="dist/VYSHYVKA-BAR-$VERSION.dmg"; rm -f "$DMG"
  hdiutil create -volname "VYSHYVKA BAR" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
  shasum -a 256 "$DMG" | tee "$DMG.sha256"
fi
