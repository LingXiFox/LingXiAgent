#!/bin/zsh
# Assemble the development MiMo bundle around an already-built dylib.
#
#   Scripts/tui-setup.sh             # build, then refresh bundle + data dir
#   Scripts/tui-setup.sh --no-build  # refresh the bundle without rebuilding
set -euo pipefail
cd "$(dirname "$0")/.."

BUILD=1
for arg in "$@"; do
  case "$arg" in
    --no-build) BUILD=0 ;;
    -h|--help)
      print -r -- "usage: $0 [--no-build]"
      exit 0
      ;;
    *)
      print -r -- "unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

if (( BUILD )); then
  swift build
elif [[ ! -f .build/debug/libMiMoProvider.dylib ]]; then
  print -r -- "error: .build/debug/libMiMoProvider.dylib is missing; run without --no-build" >&2
  exit 1
fi

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
    <key>Capabilities</key><array><string>provider.mimo</string><string>settings.view.v1</string></array>
    <key>Permissions</key><array/>
  </dict>
</dict>
</plist>
PLIST

SIGN_LOG="$(mktemp)"
if ! codesign --force --deep --sign - --identifier site.lingxi.provider.mimo "$BUNDLE" 2>"$SIGN_LOG"; then
  cat "$SIGN_LOG" >&2
  rm -f "$SIGN_LOG"
  exit 1
fi
rm -f "$SIGN_LOG"

NEW_REGISTRY=0
if [[ ! -e "$DATA/plugins.json" && ! -L "$DATA/plugins.json" ]]; then
(
setopt noclobber
cat > "$DATA/plugins.json" <<JSON
{"plugins":[{"bundleID":"site.lingxi.provider.mimo","version":"1.0.0","bundlePath":"$BUNDLE","enabled":true}]}
JSON
)
NEW_REGISTRY=1
fi

# This file maps capability ids to variable NAMES only; it never stores a key. Preserve user edits.
NEW_CREDENTIALS=0
if [[ ! -e "$DATA/credentials.json" && ! -L "$DATA/credentials.json" ]]; then
(
setopt noclobber
cat > "$DATA/credentials.json" <<'JSON'
{"provider.mimo":"MIMO_API_KEY"}
JSON
)
NEW_CREDENTIALS=1
fi

print -r -- "MiMo bundle: $BUNDLE"
print -r -- "Data dir:    $DATA"
if (( NEW_REGISTRY || NEW_CREDENTIALS )); then
  print -r -- ""
  print -r -- "First run: launch the TUI, then use /auth mimo to store the API Key in macOS Keychain."
  print -r -- "  /auth mimo update   replace the saved key"
  print -r -- "  /auth mimo remove   delete it"
  print -r -- "  /auth mimo status   report state"
fi

cat <<EOF

Security: the locally built plugin is ad-hoc signed, so LINGXI_PLUGIN_POLICY=development is required.
Development/automation may set LINGXI_CREDENTIAL_SOURCE=environment and MIMO_API_KEY explicitly;
never put the key on a command line. The Core alone reads it and plugin environments are filtered.
A changed ad-hoc Core may require macOS Keychain authorization again; a release must use a stable
signing identity. No ACL is opened to all apps. Disabling a plugin never removes saved credentials.
EOF
