#!/usr/bin/env bash
# Wrap the SwiftPM LingXiMacApp binary into a launchable .app bundle.
# A bare SwiftPM executable cannot activate as a foreground app on macOS.
set -euo pipefail

PACKAGE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
if [[ $# -gt 1 || ( "${CONFIG}" != debug && "${CONFIG}" != release ) ]]; then
    echo "Usage: $0 [debug|release]" >&2; exit 2
fi
APP_NAME="LingXiAgent"
BIN_NAME="LingXiMacApp"
OUT_DIR="${PACKAGE_ROOT}/.build/${CONFIG}"
APP_BUNDLE="${OUT_DIR}/${APP_NAME}.app"

cd "${PACKAGE_ROOT}"
swift build -c "${CONFIG}" --product "${BIN_NAME}"
# Core host ships beside the GUI binary: LingXiClient.resolveCorePath looks in
# the bundle's MacOS directory first, so Settings can start a Core on demand.
swift build -c "${CONFIG}" --product LingXiCoreHost
BIN_DIR="$(swift build -c "${CONFIG}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/${BIN_NAME}"

if [ -d "${APP_BUNDLE}" ]; then
    rm -R "${APP_BUNDLE}"
fi
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"
cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${BIN_NAME}"
cp "${BIN_DIR}/LingXiCoreHost" "${APP_BUNDLE}/Contents/MacOS/LingXiCoreHost"
# Inside the .app, Bundle.main is the app itself, so the Core's SwiftPM resource
# bundle (default configs, provider catalogs) must live in Contents/Resources.
cp -R "${BIN_DIR}/LingXiAgent_LingXiCore.bundle" "${APP_BUNDLE}/Contents/Resources/"
if [ -d "${BIN_DIR}/LingXiAgent_LingXiWebUI.bundle" ]; then
    cp -R "${BIN_DIR}/LingXiAgent_LingXiWebUI.bundle" "${APP_BUNDLE}/Contents/Resources/"
fi
# GUI resources (app icon previews for the empty workspace and About).
cp -R "${BIN_DIR}/LingXiAgent_LingXiFrontendKit.bundle" "${APP_BUNDLE}/Contents/Resources/"

# Dock icon from the Icon Composer export (Default appearance). The .icon source
# itself needs Xcode 26's actool; the .icns keeps SwiftPM builds self-contained.
ICON_SRC="${PACKAGE_ROOT}/LingXiAgent Icon/Icon-iOS-Default-1024@1x.png"
if [ -f "${ICON_SRC}" ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "${ICONSET}"
    for size in 16 32 128 256 512; do
        sips -z "${size}" "${size}" "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}.png" >/dev/null
        sips -z "$((size * 2))" "$((size * 2))" "${ICON_SRC}" --out "${ICONSET}/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "${ICONSET}" -o "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
    rm -R "$(dirname "${ICONSET}")"
fi

cat > "${APP_BUNDLE}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>              <string>LingXiMacApp</string>
  <!-- Keep the accepted GUI's identity so wallpaper and preferences survive promotion. -->
  <key>CFBundleIdentifier</key>              <string>com.lingxi.LingXiAppB</string>
  <key>CFBundleName</key>                    <string>LingXiAgent</string>
  <key>CFBundleIconFile</key>                <string>AppIcon</string>
  <key>CFBundleDevelopmentRegion</key>       <string>zh_CN</string>
  <key>CFBundleLocalizations</key>           <array><string>zh-Hans</string></array>
  <key>CFBundleDisplayName</key>             <string>LingXiAgent</string>
  <key>CFBundlePackageType</key>             <string>APPL</string>
  <key>CFBundleShortVersionString</key>      <string>__PRODUCT_VERSION__</string>
  <key>CFBundleVersion</key>                 <string>1</string>
  <key>LSMinimumSystemVersion</key>          <string>14.0</string>
  <key>NSHighResolutionCapable</key>         <true/>
  <key>NSPrincipalClass</key>                <string>NSApplication</string>
  <key>LSApplicationCategoryType</key>       <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

# The bundle's version comes from the same constant the CLI and Core report, so the
# GUI's About box cannot disagree with `lingxiagent --version`.
PRODUCT_VERSION="$(sed -nE 's/.*static let current = "([^"]+)".*/\1/p' \
    "${PACKAGE_ROOT}/Sources/LingXiProtocol/ProductVersion.swift" | head -n1)"
if [ -z "${PRODUCT_VERSION}" ]; then
    echo "cannot read ProductVersion.current from Sources/LingXiProtocol/ProductVersion.swift" >&2
    exit 1
fi
/usr/bin/sed -i '' "s/__PRODUCT_VERSION__/${PRODUCT_VERSION}/" "${APP_BUNDLE}/Contents/Info.plist"
grep -q "<key>CFBundleShortVersionString</key>              <string>${PRODUCT_VERSION}</string>" \
    "${APP_BUNDLE}/Contents/Info.plist" \
    || { echo "Info.plist did not receive the product version" >&2; exit 1; }

codesign --force --sign - --timestamp=none "${APP_BUNDLE}" >/dev/null 2>&1
echo "${APP_BUNDLE}"
