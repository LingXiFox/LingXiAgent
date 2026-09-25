#!/usr/bin/env bash
# Wrap the SwiftPM LingXiMacApp binary into a launchable .app bundle.
# A bare SwiftPM executable cannot activate as a foreground app on macOS.
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
OUT_DIR="${PACKAGE_ROOT}/.build/${CONFIG}"
APP_BUNDLE="${OUT_DIR}/LingXi.app"
BIN_NAME="LingXiMacApp"

cd "${PACKAGE_ROOT}"
swift build -c "${CONFIG}" --product LingXiMacApp
# Core host ships beside the GUI binary: LingXiClient.resolveCorePath looks in
# the bundle's MacOS directory first, so Settings can start a Core on demand.
swift build -c "${CONFIG}" --product LingXiCoreHost
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${BIN_NAME}"

rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${BIN_NAME}"
cp "${BIN_DIR}/LingXiCoreHost" "${APP_BUNDLE}/Contents/MacOS/LingXiCoreHost"
# Inside the .app, Bundle.main is the app itself, so the Core's SwiftPM resource
# bundle (default configs, provider catalogs) must live in Contents/Resources.
cp -R "${BIN_DIR}/LingXiAgent_LingXiCore.bundle" "${APP_BUNDLE}/Contents/Resources/"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>              <string>LingXiMacApp</string>
  <key>CFBundleIdentifier</key>              <string>com.lingxi.LingXiApp</string>
  <key>CFBundleName</key>                    <string>LingXi</string>
  <key>CFBundleDisplayName</key>             <string>LingXi</string>
  <key>CFBundlePackageType</key>             <string>APPL</string>
  <key>CFBundleShortVersionString</key>      <string>1.0.0</string>
  <key>CFBundleVersion</key>                 <string>1</string>
  <key>LSMinimumSystemVersion</key>          <string>14.0</string>
  <key>NSHighResolutionCapable</key>         <true/>
  <key>NSPrincipalClass</key>                <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>       <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "${APP_BUNDLE}" >/dev/null 2>&1
echo "${APP_BUNDLE}"
