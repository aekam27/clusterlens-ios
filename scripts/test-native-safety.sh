#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${PROJECT_ROOT}/.native-build"
DRIVER_SOURCE="${CLUSTERLENS_DRIVER_SOURCE:-${BUILD_ROOT}/mongo-c-driver}"
HOST_BUILD="${BUILD_ROOT}/host"
HOST_INSTALL="${BUILD_ROOT}/host-install"

if [[ ! -f "${DRIVER_SOURCE}/CMakeLists.txt" ]]; then
  echo 'Provide the existing MongoDB C Driver 2.3.3 source via CLUSTERLENS_DRIVER_SOURCE.' >&2
  echo 'This script never downloads dependencies or contacts a MongoDB server.' >&2
  exit 1
fi
mkdir -p "${BUILD_ROOT}"
# Host-only test libraries: no TLS transport, no credential access, no installation
# outside the workspace. This is not validation of the vendored iOS OpenSSL slice.
cmake -S "${DRIVER_SOURCE}" -B "${HOST_BUILD}" \
  -DENABLE_MONGOC=ON -DENABLE_STATIC=ON -DENABLE_SHARED=OFF \
  -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_SSL=OFF \
  -DENABLE_SASL=OFF -DENABLE_SRV=OFF -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF \
  -DENABLE_MONGODB_AWS_AUTH=OFF -DENABLE_SNAPPY=OFF -DENABLE_ZSTD=OFF \
  -DENABLE_ZLIB=OFF -DENABLE_SHM_COUNTERS=OFF -DENABLE_UNINSTALL=OFF \
  > "${BUILD_ROOT}/configure.log" 2>&1
cmake --build "${HOST_BUILD}" --target mongoc_static --parallel 4 > "${BUILD_ROOT}/build.log" 2>&1
cmake --install "${HOST_BUILD}" --prefix "${HOST_INSTALL}" > "${BUILD_ROOT}/install.log" 2>&1
clang -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  -I "${HOST_INSTALL}/include/mongoc-2.3.3" -I "${HOST_INSTALL}/include/bson-2.3.3" \
  "${PROJECT_ROOT}/tests/native/bridge_safety_tests.c" \
  "${HOST_INSTALL}/lib/libmongoc2.a" "${HOST_INSTALL}/lib/libbson2.a" \
  -lpthread -lresolv -o "${BUILD_ROOT}/bridge_safety_tests"
"${BUILD_ROOT}/bridge_safety_tests"
