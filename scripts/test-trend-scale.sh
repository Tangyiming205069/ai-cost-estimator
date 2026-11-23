#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-cache
xcrun swiftc -module-cache-path "$PWD/.build-cache" LMCost/TrendScale.swift tests/TrendScaleTests.swift -o .build-cache/trend-scale-tests
.build-cache/trend-scale-tests
