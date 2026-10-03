#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${PROJECT_ROOT}/.native-build"
# Run the foundation/native scripts first to build these offline test executables.
"${BUILD_ROOT}/bridge_safety_tests" --export-numeric-fixture > "${BUILD_ROOT}/numeric-native.json"
"${BUILD_ROOT}/foundation_checks" "${BUILD_ROOT}/numeric-native.json" "${BUILD_ROOT}/numeric-swift.json"
"${BUILD_ROOT}/bridge_safety_tests" --verify-numeric-fixture "${BUILD_ROOT}/numeric-swift.json"
