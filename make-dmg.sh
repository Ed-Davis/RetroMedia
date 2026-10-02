#!/bin/bash
# Builds "build/RetroMedia.app" (sandboxed, ad-hoc signed) and a test DMG.
# Set SIGN_IDENTITY to sign with a Developer ID instead.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="RetroMedia"
EXEC="RetroMedia"
BUNDLE_ID="com.ed1t.retromedia"
VERSION="$(tr -d '[:space:]' < Packaging/VERSION)"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="build/${APP_NAME}.app"

echo "▸ Building ${APP_NAME} ${VERSION} (${BUILD})…"
swift build -c release --product "$EXEC"
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXEC" "$APP/Contents/MacOS/$EXEC"
cp Sources/RetroMedia/Resources/AppIcon.png "$APP/Contents/Resources/AppIcon.png"

echo "▸ Making the icon…"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>        <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>         <string>${EXEC}</string>
    <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>${VERSION}</string>
    <key>CFBundleVersion</key>            <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>     <string>14.0</string>
    <key>LSApplicationCategoryType</key>  <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>   <string>© 2026 Ed Davis</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>        <string>com.ed1t.retromedia.items</string>
            <key>UTTypeDescription</key>       <string>RetroMedia items</string>
            <key>UTTypeConformsTo</key>        <array><string>public.data</string></array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>       <string>Disk Image</string>
            <key>CFBundleTypeRole</key>       <string>Editor</string>
            <key>LSHandlerRank</key>          <string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>img</string><string>ima</string><string>hda</string><string>hds</string><string>hdf</string><string>dsk</string><string>vfd</string><string>flp</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>       <string>CD Image</string>
            <key>CFBundleTypeRole</key>       <string>Viewer</string>
            <key>LSHandlerRank</key>          <string>Alternate</string>
            <key>CFBundleTypeExtensions</key> <array><string>iso</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --options runtime --entitlements Packaging/RetroMedia.entitlements --sign "${SIGN_IDENTITY:--}" "$APP"

DMG="build/${APP_NAME} ${VERSION} (test).dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "${APP_NAME}" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "✓ $DMG"
