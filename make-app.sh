#!/bin/bash
# Builds Strollo.app into ~/Applications and launches it.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="$HOME/Applications/Strollo.app"
pkill -x Strollo 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/Strollo "$APP/Contents/MacOS/Strollo"
# Built-in character 2 and the app icon live in Resources/ (committed, so the app builds from a fresh clone).
# If the raw prepared frames are present (character/sprites, not in the repo), refresh Resources/ from them first:
# frames are packed as HEIC with transparency, about a seventh of the size of the PNGs and visually the same.
if [ -d character/sprites ]; then
  if [ ! -x .build/pack-character ] || [ tools/pack-character.swift -nt .build/pack-character ]; then
    swiftc -O tools/pack-character.swift -o .build/pack-character
  fi
  .build/pack-character character/sprites Resources/character2 0.6
  if [ ! -x .build/make-icon ] || [ tools/make-icon.swift -nt .build/make-icon ]; then
    swiftc -O tools/make-icon.swift -o .build/make-icon
  fi
  .build/make-icon character/sprites/idle.png .build/AppIcon.iconset
  iconutil -c icns .build/AppIcon.iconset -o Resources/AppIcon.icns
fi
mkdir -p "$APP/Contents/Resources/character2"
cp Resources/character2/* "$APP/Contents/Resources/character2/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.kaisarsofi.strollo</string>
  <key>CFBundleName</key><string>Strollo</string>
  <key>CFBundleExecutable</key><string>Strollo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
touch "$APP"   # nudges Finder to pick up a changed icon
echo "Installed $APP"
[ "$1" = "--no-launch" ] || open "$APP"
