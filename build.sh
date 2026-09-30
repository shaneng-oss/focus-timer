#!/bin/zsh
# Builds "Focus Timer.app" and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
swiftc -O -enforce-exclusivity=unchecked -swift-version 5 -target arm64-apple-macos14.0 *.swift -o SandTimer
APP="build/Focus Timer.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp SandTimer "$APP/Contents/MacOS/SandTimer"
# App icon rendered by the app itself
./SandTimer --snapshot build/icon.png --progress 0.38 --icon
ICONSET=build/AppIcon.iconset && mkdir -p $ICONSET
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out $ICONSET/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out $ICONSET/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns $ICONSET -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Focus Timer</string>
  <key>CFBundleDisplayName</key><string>Focus Timer</string>
  <key>CFBundleIdentifier</key><string>com.focustimer.app</string>
  <key>CFBundleExecutable</key><string>SandTimer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep -s - "$APP"
pkill -x SandTimer 2>/dev/null || true
rm -rf ~/Applications/"Sand Timer.app" ~/Applications/"Focus Timer.app"
cp -R "$APP" ~/Applications/
echo "Installed to ~/Applications/Focus Timer.app"
