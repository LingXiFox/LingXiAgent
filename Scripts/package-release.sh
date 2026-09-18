#!/usr/bin/env bash
# ==============================================================================
#  🦊 LingXiAgent Release Packager
#  Packages release artifacts for macOS, Linux, or Windows.
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin)
        PLATFORM="macos"
        ;;
    Linux)
        PLATFORM="linux"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        PLATFORM="windows"
        ;;
    *)
        PLATFORM="$(echo "$OS" | tr '[:upper:]' '[:lower:]')"
        ;;
esac

case "$ARCH" in
    arm64|aarch64)
        CPU_ARCH="arm64"
        ;;
    x86_64|amd64)
        CPU_ARCH="x86_64"
        ;;
    *)
        CPU_ARCH="$ARCH"
        ;;
esac

echo "🦊 [1/3] Building Release binaries for $PLATFORM-$CPU_ARCH..."
cd "$ROOT_DIR"
swift build -c release --product lingxiagent
swift build -c release --product LingXiCoreHost

BIN_DIR="$(swift build -c release --show-bin-path)"
VERSION="${1:-$(grep 'public static let version = "' Sources/LingXiTUI/CLIParser.swift 2>/dev/null | head -n1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "0.2.0-alpha.1")}"

STAGING_DIR="$(mktemp -d /tmp/lingxiagent-pkg.XXXXXX)"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "📦 [2/3] Staging artifacts (version: $VERSION)..."
if [ "$PLATFORM" = "windows" ]; then
    cp -f "$BIN_DIR/lingxiagent.exe" "$STAGING_DIR/"
    if [ -f "$BIN_DIR/LingXiCoreHost.exe" ]; then
        cp -f "$BIN_DIR/LingXiCoreHost.exe" "$STAGING_DIR/"
    fi
    ARCHIVE_NAME="lingxiagent-windows-$CPU_ARCH.zip"
    (
        cd "$STAGING_DIR"
        zip -r "$DIST_DIR/$ARCHIVE_NAME" ./*
    )
else
    cp -f "$BIN_DIR/lingxiagent" "$STAGING_DIR/"
    if [ -f "$BIN_DIR/LingXiCoreHost" ]; then
        cp -f "$BIN_DIR/LingXiCoreHost" "$STAGING_DIR/"
    fi
    if [ -d "$BIN_DIR/LingXiAgent_LingXiCore.bundle" ]; then
        cp -R "$BIN_DIR/LingXiAgent_LingXiCore.bundle" "$STAGING_DIR/"
    fi
    mkdir -p "$STAGING_DIR/Sidecars/browser-host"
    if [ -d "$ROOT_DIR/Sidecars/browser-host" ]; then
        cp -f "$ROOT_DIR/Sidecars/browser-host/index.mjs" "$STAGING_DIR/Sidecars/browser-host/"
        cp -f "$ROOT_DIR/Sidecars/browser-host/package.json" "$STAGING_DIR/Sidecars/browser-host/"
    fi
    ARCHIVE_NAME="lingxiagent-$PLATFORM-$CPU_ARCH.tar.gz"
    tar -czf "$DIST_DIR/$ARCHIVE_NAME" -C "$STAGING_DIR" .
fi

echo "🔐 [3/3] Generating checksum..."
cd "$DIST_DIR"
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
fi

echo "✅ Release package created: $DIST_DIR/$ARCHIVE_NAME"
ls -lh "$DIST_DIR/$ARCHIVE_NAME"
cat "$DIST_DIR/$ARCHIVE_NAME.sha256"
