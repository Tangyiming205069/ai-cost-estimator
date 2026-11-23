#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-cache
xcrun swiftc -module-cache-path "$PWD/.build-cache" LMCost/DateRangeSelection.swift tests/DateRangeSelectionTests.swift -o .build-cache/date-range-tests
.build-cache/date-range-tests
