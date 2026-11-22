#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || { echo 'Requires an Apple silicon Mac.' >&2; exit 1; }
MAC_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAC_MAJOR" -ge 26 ] || { echo 'This preview requires macOS 26 or later.' >&2; exit 1; }
SDK=$(xcrun --sdk macosx --show-sdk-path)
SDK_MAJOR=$(xcrun --sdk macosx --show-sdk-version | cut -d. -f1)
[ "$SDK_MAJOR" -ge 26 ] || { echo 'Apple SDK 26+ is required. No developer settings were changed.' >&2; exit 1; }
SWIFT=$(xcrun --find swiftc)
COMPANION_PYTHON=${COMPANION_PYTHON:-}
if [ -z "$COMPANION_PYTHON" ]; then
  for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3; do
    if [ -x "$candidate" ] && "$candidate" -B -c 'import sys; from compression import zstd; assert sys.version_info >= (3,14)' 2>/dev/null; then COMPANION_PYTHON=$candidate; break; fi
  done
fi
[ -n "$COMPANION_PYTHON" ] || { echo 'Python 3.14+ is required. Set COMPANION_PYTHON to its absolute executable path.' >&2; exit 1; }
"$COMPANION_PYTHON" -B -c 'import sys; from compression import zstd; assert sys.version_info >= (3,14)'
if [ "${1:-}" = --check ]; then echo 'Requirements satisfied: Apple silicon, macOS/SDK 26+, Python 3.14+.'; exit 0; fi
[ "$#" -eq 0 ] || { echo 'Usage: bash build.sh [--check]' >&2; exit 2; }
OUT=${COMPANION_OUTPUT_DIR:-"$PWD/dist"}
APP="$OUT/AI Cost Estimator.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" .build-cache
"$SWIFT" -module-cache-path "$PWD/.build-cache" -sdk "$SDK" -target arm64-apple-macosx26.0 -O LMCost/WindowPlacement.swift LMCost/App.swift -o "$APP/Contents/MacOS/AI Cost Estimator"
cp LMCost/engine.py LMCost/codex_hook.py LMCost/subscriptions.py LMCost/conversation_titles.py LMCost/history_import.py LMCost/history_sync.py LMCost/pricing.json LMCost/localization.en.json "$APP/Contents/Resources/"
"$COMPANION_PYTHON" -B - "$APP" "$COMPANION_PYTHON" <<'PY'
import plistlib,sys
from pathlib import Path
app=Path(sys.argv[1]);python=sys.argv[2]
info=dict(CFBundleExecutable='AI Cost Estimator',CFBundleIdentifier='com.aicostestimator.companion',CFBundleName='AI Cost Estimator',CFBundleDisplayName='AI Cost Estimator',CFBundleVersion='9',CFBundleShortVersionString='0.3.0',CFBundlePackageType='APPL',LSMinimumSystemVersion='26.0',LSUIElement=True,NSHighResolutionCapable=True,AICostPython=python)
with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump(info,f)
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
echo "Built: $APP"
