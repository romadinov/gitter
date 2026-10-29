#!/bin/sh
# Builds a release binary and wraps it into build/Gitter.app (with icon and Info.plist).
set -e
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
swift build -c "$CONFIG"
APP=build/Gitter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Gitter" "$APP/Contents/MacOS/Gitter"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Gitter</string>
    <key>CFBundleIdentifier</key><string>dev.gitter.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Gitter</string>
    <key>CFBundleDisplayName</key><string>Gitter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Free and open source.</string>
    <key>NSAppleEventsUsageDescription</key><string>Gitter uses Terminal to open a shell in your repository.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array><string>public.folder</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
if [ -f Scripts/make-icon.swift ]; then
    swift Scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns" || echo "icon generation skipped"
fi
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
