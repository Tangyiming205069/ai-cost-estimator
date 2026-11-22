#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-cache
xcrun swiftc -module-cache-path "$PWD/.build-cache" LMCost/WindowPlacement.swift tests/WindowPlacementTests.swift -o .build-cache/window-placement-tests
.build-cache/window-placement-tests
