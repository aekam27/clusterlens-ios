#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${PROJECT_ROOT}/.native-build"
# Build the offline executables with test-foundation.sh and test-native-safety.sh first.
"${BUILD_ROOT}/bridge_safety_tests" --export-browse-fixture > "${BUILD_ROOT}/browse-native.json"
"${BUILD_ROOT}/foundation_checks" --validate-browse-fixture "${BUILD_ROOT}/browse-native.json"
