#!/bin/zsh
# One-command launcher for the LingXi TUI.
#
#   Scripts/tui.sh              # build, refresh the development plugin bundle, launch
#   Scripts/tui.sh --no-build   # launch the existing build
#
# The Core loads plugins only in development policy because the locally built MiMo
# bundle is ad-hoc signed. A custom registry can be supplied via LINGXI_DATA_DIR;
# it must already contain plugins.json.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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
      print -r -- "usage: $0 [--no-build]" >&2
      exit 2
      ;;
  esac
done

DATA="${LINGXI_DATA_DIR:-$ROOT/dist/data}"
BUNDLE="$ROOT/dist/MiMoProvider.lxap"
DYLIB="$ROOT/.build/debug/libMiMoProvider.dylib"

if (( BUILD )); then
  swift build
fi

if [[ "$DATA" == "$ROOT/dist/data" ]]; then
  # Refresh the bundle when it is missing or older than the dylib just built.
  if [[ ! -f "$DATA/plugins.json" || ! -x "$BUNDLE/Contents/MacOS/MiMoProvider" || "$DYLIB" -nt "$BUNDLE/Contents/MacOS/MiMoProvider" ]]; then
    # The build above (or the explicit --no-build) already owns the dylib; never build twice.
    "$ROOT/Scripts/tui-setup.sh" --no-build
  fi
elif [[ ! -f "$DATA/plugins.json" ]]; then
  print -r -- "error: $DATA/plugins.json is missing; point LINGXI_DATA_DIR at an existing registry" >&2
  exit 1
fi

if [[ ! -x "$ROOT/.build/debug/LingXiTUI" ]]; then
  print -r -- "error: .build/debug/LingXiTUI is missing; run without --no-build" >&2
  exit 1
fi

export LINGXI_PLUGIN_POLICY="${LINGXI_PLUGIN_POLICY:-development}"
export LINGXI_DATA_DIR="$DATA"
exec "$ROOT/.build/debug/LingXiTUI"
