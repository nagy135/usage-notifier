#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -parse-as-library Sources/UsageData.swift Sources/UsageProviders.swift Sources/UsageModel.swift Tests/UsageTests.swift \
    -o build/usage-tests -framework Foundation -framework Security -framework Combine
build/usage-tests
