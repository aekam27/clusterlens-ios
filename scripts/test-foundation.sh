#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${PROJECT_ROOT}/.native-build"
mkdir -p "${BUILD_ROOT}"
CLANG_MODULE_CACHE_PATH="${BUILD_ROOT}/clang-cache" swiftc -swift-version 5 \
  -module-cache-path "${BUILD_ROOT}/swift-module-cache" \
  "${PROJECT_ROOT}/ios/ClusterLens/Core/JSONValue.swift" \
  "${PROJECT_ROOT}/ios/ClusterLens/Core/Models.swift" \
  "${PROJECT_ROOT}/ios/ClusterLens/Core/MongoConnectionString.swift" \
  "${PROJECT_ROOT}/tests/swift/FoundationChecks.swift" \
  -o "${BUILD_ROOT}/foundation_checks"
"${BUILD_ROOT}/foundation_checks"
