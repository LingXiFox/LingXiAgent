#!/usr/bin/env bash
# ==============================================================================
#  🦊 LingXiAgent Alpha 1 Build & CLI Test Runner
#  Compiles Alpha release artifacts into dist/alpha-1/ and creates ./lingxiagent-alpha
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
ALPHA_DIR="$DIST_DIR/alpha-1"
ALPHA_BIN_DIR="$ALPHA_DIR/bin"
SYMLINK_PATH="$ROOT_DIR/lingxiagent-alpha"

VERSION="0.2.0-alpha.1"
RELEASE_NAME="Alpha 1"

DO_BUILD=1
DO_TEST=0
DO_PACKAGE=0
BUILD_CONFIG="release"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test|-t)
            DO_TEST=1
            shift
            ;;
        --package|-p)
            DO_PACKAGE=1
            shift
            ;;
        --debug|-d)
            BUILD_CONFIG="debug"
            shift
            ;;
        --clean|-c)
            echo "🧹 Cleaning Alpha build artifacts..."
            rm -rf "$ALPHA_DIR" "$SYMLINK_PATH"
            echo "✨ Clean completed."
            exit 0
            ;;
        --help|-h)
            cat <<EOF
Usage: $0 [options]

Options:
  --test, -t       Run CLI smoke tests after building
  --package, -p    Package dist/alpha-1 into a distributable archive with checksum
  --debug, -d      Build using debug configuration instead of release
  --clean, -c      Remove dist/alpha-1 and ./lingxiagent-alpha symlink
  --help, -h       Show this help message
EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=================================================================="
echo "🦊 LingXiAgent Build - Version $VERSION ($RELEASE_NAME)"
echo "   Configuration: $BUILD_CONFIG"
echo "   Artifact Dir:  $ALPHA_DIR"
echo "=================================================================="

# 1. Build targets
cd "$ROOT_DIR"
echo "🔨 [1/4] Compiling targets (lingxiagent, LingXiCoreHost, LingXiTUI)..."
swift build -c "$BUILD_CONFIG" --product lingxiagent
swift build -c "$BUILD_CONFIG" --product LingXiCoreHost
swift build -c "$BUILD_CONFIG" --product LingXiTUI

BIN_DIR="$(swift build -c "$BUILD_CONFIG" --show-bin-path)"

# 2. Stage artifacts
echo "📦 [2/4] Staging artifacts into $ALPHA_BIN_DIR..."
mkdir -p "$ALPHA_BIN_DIR"

cp -f "$BIN_DIR/lingxiagent" "$ALPHA_BIN_DIR/"
if [ -f "$BIN_DIR/LingXiCoreHost" ]; then
    cp -f "$BIN_DIR/LingXiCoreHost" "$ALPHA_BIN_DIR/"
fi
if [ -f "$BIN_DIR/LingXiTUI" ]; then
    cp -f "$BIN_DIR/LingXiTUI" "$ALPHA_BIN_DIR/"
fi
if [ -d "$BIN_DIR/LingXiAgent_LingXiCore.bundle" ]; then
    cp -R "$BIN_DIR/LingXiAgent_LingXiCore.bundle" "$ALPHA_BIN_DIR/"
fi

# Create convenient symlink at repo root
ln -sf "dist/alpha-1/bin/lingxiagent" "$SYMLINK_PATH"
chmod +x "$SYMLINK_PATH" "$ALPHA_BIN_DIR/lingxiagent"
if [ -f "$ALPHA_BIN_DIR/LingXiCoreHost" ]; then
    chmod +x "$ALPHA_BIN_DIR/LingXiCoreHost"
fi
if [ -f "$ALPHA_BIN_DIR/LingXiTUI" ]; then
    chmod +x "$ALPHA_BIN_DIR/LingXiTUI"
fi

# Write metadata
cat <<EOF > "$ALPHA_DIR/release-info.json"
{
  "version": "$VERSION",
  "releaseName": "$RELEASE_NAME",
  "buildConfig": "$BUILD_CONFIG",
  "builtAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "gitCommit": "$(git rev-parse HEAD 2>/dev/null || echo "unknown")",
  "gitBranch": "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
}
EOF

echo "✅ [2/4] Artifacts staged successfully!"
echo "   👉 Repo CLI Entrypoint: ./lingxiagent-alpha"

# 3. Optional Packaging
if [ "$DO_PACKAGE" -eq 1 ]; then
    echo "📦 [3/4] Packaging distributable archive..."
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    ARCH="$(uname -m)"
    case "$ARCH" in
        arm64|aarch64) ARCH_NAME="arm64" ;;
        x86_64|amd64) ARCH_NAME="x86_64" ;;
        *) ARCH_NAME="$ARCH" ;;
    esac
    
    PKG_NAME="lingxiagent-$VERSION-$OS-$ARCH_NAME.tar.gz"
    tar -czf "$DIST_DIR/$PKG_NAME" -C "$ALPHA_DIR" .
    
    if command -v shasum >/dev/null 2>&1; then
        (cd "$DIST_DIR" && shasum -a 256 "$PKG_NAME" > "$PKG_NAME.sha256")
    elif command -v sha256sum >/dev/null 2>&1; then
        (cd "$DIST_DIR" && sha256sum "$PKG_NAME" > "$PKG_NAME.sha256")
    fi
    echo "✅ Release package created at $DIST_DIR/$PKG_NAME"
fi

# 4. Optional Smoke Tests
if [ "$DO_TEST" -eq 1 ]; then
    echo "🧪 [4/4] Running CLI smoke tests using ./lingxiagent-alpha..."
    
    echo "--- Test 1: Version Check ---"
    VERSION_OUTPUT="$("$SYMLINK_PATH" --version)"
    echo "$VERSION_OUTPUT"
    echo "$VERSION_OUTPUT" | grep -q "$VERSION" || (echo "❌ Version check failed!" && exit 1)
    echo "✓ Version check passed."

    echo "--- Test 2: Help Output ---"
    "$SYMLINK_PATH" --help > /dev/null
    echo "✓ Help check passed."

    echo "--- Test 3: Doctor Diagnostic ---"
    "$SYMLINK_PATH" doctor > /dev/null
    echo "✓ Doctor diagnostic passed."

    echo "--- Test 4: Auth Matrix ---"
    "$SYMLINK_PATH" auth matrix > /dev/null
    echo "✓ Auth matrix command passed."

    echo "--- Test 5: MCP List ---"
    "$SYMLINK_PATH" mcp list > /dev/null
    echo "✓ MCP list command passed."

    echo "--- Test 6: Skills List ---"
    "$SYMLINK_PATH" skills list > /dev/null
    echo "✓ Skills list command passed."

    echo "--- Test 7: Completion Generation ---"
    "$SYMLINK_PATH" completion bash > /dev/null
    echo "✓ Completion generation passed."

    echo "🎉 All CLI smoke tests passed successfully!"
fi

echo "=================================================================="
echo "🦊 Alpha 1 ready! You can now test CLI commands via:"
echo "   $ ./lingxiagent-alpha --version"
echo "   $ ./lingxiagent-alpha doctor"
echo "   $ ./lingxiagent-alpha auth matrix"
echo "   $ ./lingxiagent-alpha mcp list"
echo "   $ ./lingxiagent-alpha skills list"
echo "   $ ./lingxiagent-alpha exec \"<prompt>\""
echo "   $ ./lingxiagent-alpha"
echo "=================================================================="
