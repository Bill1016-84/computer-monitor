#!/bin/zsh
# Builds ComputerMonitor.app (menu bar hardware monitor)
set -e
cd "$(dirname "$0")"
APP=build/ComputerMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/ComputerMonitor" Sources/*.swift \
  -framework AppKit -framework IOKit -framework ServiceManagement
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ComputerMonitor</string>
  <key>CFBundleDisplayName</key><string>Computer Monitor</string>
  <key>CFBundleIdentifier</key><string>local.computer-monitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>ComputerMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
cp Resources/AppIcon.icns Resources/Animations/*.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
