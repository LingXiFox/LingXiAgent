#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build

DIST="$PWD/dist"
BUNDLE="$DIST/MiMoProvider.lxap"
DATA="$DIST/data"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$DATA"
cp .build/debug/libMiMoProvider.dylib "$BUNDLE/Contents/MacOS/MiMoProvider"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>site.lingxi.provider.mimo</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleExecutable</key><string>MiMoProvider</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LingXiPlugin</key>
  <dict>
    <key>ABIMajor</key><integer>1</integer>
    <key>MinimumCoreVersion</key><string>2.0.0</string>
    <key>EntryPoint</key><string>LingXiPlugin_Init</string>
    <key>Capabilities</key><array><string>provider.mimo</string></array>
    <key>Permissions</key><array/>
  </dict>
</dict>
</plist>
PLIST

codesign --force --deep --sign - --identifier site.lingxi.provider.mimo "$BUNDLE"

cat > "$DATA/plugins.json" <<JSON
{"plugins":[{"bundleID":"site.lingxi.provider.mimo","version":"1.0.0","bundlePath":"$BUNDLE","enabled":true}]}
JSON

cat <<EOF
MiMo bundle: $BUNDLE
Data dir:    $DATA

Run the TUI (the key stays in your shell; the TUI never reads it):

  MIMO_API_KEY=... LINGXI_PLUGIN_POLICY=development LINGXI_DATA_DIR="$DATA" swift run LingXiTUI

If MIMO_API_KEY is already exported, omit it. LINGXI_PLUGIN_POLICY=development is required because
the locally built bundle is ad-hoc signed; the default restricted tier refuses it by design.
EOF
