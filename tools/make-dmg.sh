#!/bin/bash
# Builds dist/Strollo.dmg from the installed app: a window with the app, an Applications shortcut and an arrow.
#   ./tools/make-dmg.sh [path/to/Strollo.app]
set -e
cd "$(dirname "$0")/.."
APP="${1:-$HOME/Applications/Strollo.app}"
VOL="Strollo"
OUT="dist/Strollo.dmg"
mkdir -p dist .build
if [ ! -x .build/dmg-bg ] || [ tools/make-dmg-background.swift -nt .build/dmg-bg ]; then
  swiftc -O tools/make-dmg-background.swift -o .build/dmg-bg
fi
.build/dmg-bg .build/dmg-bg.png

# detach anything left over from an earlier run
hdiutil detach "/Volumes/$VOL" -force >/dev/null 2>&1 || true
rm -f .build/rw.dmg "$OUT"
SIZE=$(( $(du -sm "$APP" | cut -f1) + 40 ))
hdiutil create -quiet -size ${SIZE}m -fs HFS+ -volname "$VOL" -type UDIF .build/rw.dmg
hdiutil attach -quiet -readwrite -noverify -noautoopen .build/rw.dmg
MNT="/Volumes/$VOL"
ditto "$APP" "$MNT/Strollo.app"
ln -s /Applications "$MNT/Applications"
mkdir "$MNT/.background" && cp .build/dmg-bg.png "$MNT/.background/background.png"

# window layout (Finder remembers it in .DS_Store); a plain DMG still works if this step is skipped
osascript >/dev/null 2>&1 <<OSA || echo "note: could not style the window (Finder automation not allowed); the DMG still works"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set background picture of opts to file ".background:background.png"
    set position of item "Strollo.app" of container window to {170, 190}
    set position of item "Applications" of container window to {490, 190}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
sync
hdiutil detach -quiet "$MNT" || hdiutil detach -quiet -force "$MNT"
hdiutil convert -quiet .build/rw.dmg -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -f .build/rw.dmg
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
