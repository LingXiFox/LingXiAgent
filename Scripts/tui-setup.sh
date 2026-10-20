#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

swift build

DIST="$PWD/dist"
BUNDLE="$DIST/MiMoProvider.lxap"
DATA="$DIST/data"
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

if [[ ! -e "$DATA/plugins.json" && ! -L "$DATA/plugins.json" ]]; then
(
setopt noclobber
cat > "$DATA/plugins.json" <<JSON
{"plugins":[{"bundleID":"site.lingxi.provider.mimo","version":"1.0.0","bundlePath":"$BUNDLE","enabled":true}]}
JSON
)
fi

# This file maps capability ids to variable NAMES only; it never stores a key. Preserve user edits.
if [[ ! -e "$DATA/credentials.json" && ! -L "$DATA/credentials.json" ]]; then
(
setopt noclobber
cat > "$DATA/credentials.json" <<'JSON'
{"provider.mimo":"MIMO_API_KEY"}
JSON
)
fi

cat <<EOF
MiMo bundle: $BUNDLE
Data dir:    $DATA

Run the TUI, then enter /auth mimo to save your API Key in macOS Keychain:

  LINGXI_PLUGIN_POLICY=development LINGXI_DATA_DIR="$DATA" .build/debug/LingXiTUI

/auth mimo update replaces the saved key; /auth mimo remove deletes it; /auth mimo status reports state.
Existing plugins.json and credentials.json are preserved. If your registry predates this bundle,
install/enable MiMo in that registry first. Disabling a plugin never removes saved credentials.

Development/automation only: explicitly set LINGXI_CREDENTIAL_SOURCE=environment and MIMO_API_KEY.
Never put the key on a command line. The Core alone reads the variable; plugin environments are filtered.
The locally built plugin is ad-hoc signed, so LINGXI_PLUGIN_POLICY=development is required.
The same Core build can reuse Keychain across restarts. A changed ad-hoc Core may require macOS
Keychain authorization again; a release must use a stable signing identity. No ACL is opened to all apps.
EOF
