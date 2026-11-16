#!/bin/bash
# Local source installer. No downloads, sudo, telemetry, agent config or security changes.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="$HOME/Applications/AI Cost Estimator.app"
OPEN_APP=1
CHECK=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --destination) [ "$#" -ge 2 ] || exit 2; DEST=$2; shift 2 ;;
    --no-open) OPEN_APP=0; shift ;;
    *) echo 'Usage: bash scripts/install.sh [--check] [--destination /absolute/path/AI\ Cost\ Estimator.app] [--no-open]' >&2; exit 2 ;;
  esac
done
if [ "$CHECK" -eq 1 ]; then exec bash build.sh --check; fi
case "$DEST" in /*.app) ;; *) echo 'Destination must be an absolute .app path.' >&2; exit 2 ;; esac
case "$DEST" in /Applications/*|/System/*|/Library/*) echo 'System installation paths are not supported.' >&2; exit 1 ;; esac
[ ! -e "$DEST" ] && [ ! -L "$DEST" ] || { echo 'Destination already exists. Nothing was replaced; choose a new destination.' >&2; exit 1; }
# Pin the build output; caller-controlled output paths do not change what is installed.
COMPANION_OUTPUT_DIR="$PWD/dist" bash build.sh
mkdir -p "$(dirname "$DEST")"
/usr/bin/ditto "$PWD/dist/AI Cost Estimator.app" "$DEST"
codesign --verify --strict "$DEST"
echo "Installed: $DEST"
echo 'Collection remains off until you connect in the app. No login item was created.'
if [ "$OPEN_APP" -eq 1 ]; then /usr/bin/open "$DEST"; fi
