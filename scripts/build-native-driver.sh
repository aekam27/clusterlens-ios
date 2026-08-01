#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${PROJECT_ROOT}/.native-build"
DRIVER_SOURCE="${BUILD_ROOT}/mongo-c-driver"
OPENSSL_ROOT="${BUILD_ROOT}/openssl"
VENDOR_ROOT="${PROJECT_ROOT}/ios/Vendor"
DRIVER_TAG="2.3.3"
OPENSSL_TAG="3.6.3000"
OPENSSL_CHECKSUM="6c4b064d12b8de2ae77ac59fbcbbd1c20b4fecfb7fc50b8ab326347c52ecbf0c"

for command_name in cmake git curl unzip xcodebuild xcrun; do
  command -v "${command_name}" >/dev/null || {
    echo "Missing required command: ${command_name}" >&2
    exit 1
  }
done

mkdir -p "${BUILD_ROOT}" "${OPENSSL_ROOT}"

if [[ ! -d "${DRIVER_SOURCE}/.git" ]]; then
  git clone --depth 1 --branch "${DRIVER_TAG}" https://github.com/mongodb/mongo-c-driver.git "${DRIVER_SOURCE}"
  git -C "${DRIVER_SOURCE}" apply "${PROJECT_ROOT}/driver-patches/ios-compat.patch"
fi

OPENSSL_ZIP="${BUILD_ROOT}/OpenSSL.xcframework.zip"
if [[ ! -f "${OPENSSL_ZIP}" ]]; then
  curl -fL "https://github.com/krzyzanowskim/OpenSSL/releases/download/${OPENSSL_TAG}/OpenSSL.xcframework.zip" -o "${OPENSSL_ZIP}"
fi
echo "${OPENSSL_CHECKSUM}  ${OPENSSL_ZIP}" | shasum -a 256 -c -

if [[ ! -d "${OPENSSL_ROOT}/OpenSSL.xcframework" ]]; then
  unzip -q "${OPENSSL_ZIP}" -d "${OPENSSL_ROOT}"
fi

mkdir -p "${BUILD_ROOT}/openssl-include"
ln -sfn "${OPENSSL_ROOT}/OpenSSL.xcframework/ios-arm64/OpenSSL.framework/Headers" "${BUILD_ROOT}/openssl-include/OpenSSL"

build_slice() {
  local slice_name="$1"
  local sdk_name="$2"
  local openssl_binary="$3"
  local build_dir="${BUILD_ROOT}/build-${slice_name}"
  local install_dir="${BUILD_ROOT}/install-${slice_name}"

  cmake -S "${DRIVER_SOURCE}" -B "${build_dir}" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="${sdk_name}" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DENABLE_MONGOC=ON \
    -DENABLE_STATIC=ON \
    -DENABLE_SHARED=OFF \
    -DENABLE_TESTS=OFF \
    -DENABLE_EXAMPLES=OFF \
    -DENABLE_MAN_PAGES=OFF \
    -DENABLE_HTML_DOCS=OFF \
    -DENABLE_SSL=OPENSSL \
    -DENABLE_SRV=OFF \
    -DENABLE_SASL=OFF \
    -DENABLE_SNAPPY=OFF \
    -DENABLE_ZSTD=OFF \
    -DENABLE_ZLIB=OFF \
    -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF \
    -DENABLE_MONGODB_AWS_AUTH=OFF \
    -DENABLE_SHM_COUNTERS=OFF \
    -DENABLE_TRACING=OFF \
    -DENABLE_MAINTAINER_FLAGS=OFF \
    -DOPENSSL_INCLUDE_DIR="${BUILD_ROOT}/openssl-include" \
    -DOPENSSL_SSL_LIBRARY="${openssl_binary}" \
    -DOPENSSL_CRYPTO_LIBRARY="${openssl_binary}"

  cmake --build "${build_dir}" --config Release --target mongoc_static --parallel 1
  cmake --install "${build_dir}" --config Release --prefix "${install_dir}"
}

build_slice \
  simulator \
  iphonesimulator \
  "${OPENSSL_ROOT}/OpenSSL.xcframework/ios-arm64_x86_64-simulator/OpenSSL.framework/OpenSSL"

build_slice \
  device \
  iphoneos \
  "${OPENSSL_ROOT}/OpenSSL.xcframework/ios-arm64/OpenSSL.framework/OpenSSL"

DRIVER_HEADERS="${BUILD_ROOT}/headers"
mkdir -p "${BUILD_ROOT}/combined" "${DRIVER_HEADERS}"
cp -R "${BUILD_ROOT}/install-simulator/include/mongoc-${DRIVER_TAG}/mongoc" "${DRIVER_HEADERS}/"
cp -R "${BUILD_ROOT}/install-simulator/include/bson-${DRIVER_TAG}/bson" "${DRIVER_HEADERS}/"

xcrun libtool -static \
  -o "${BUILD_ROOT}/combined/libMongoCDriver-simulator.a" \
  "${BUILD_ROOT}/install-simulator/lib/libmongoc2.a" \
  "${BUILD_ROOT}/install-simulator/lib/libbson2.a"

xcrun libtool -static \
  -o "${BUILD_ROOT}/combined/libMongoCDriver-device.a" \
  "${BUILD_ROOT}/install-device/lib/libmongoc2.a" \
  "${BUILD_ROOT}/install-device/lib/libbson2.a"

rm -rf "${VENDOR_ROOT}/MongoCDriver.xcframework" "${VENDOR_ROOT}/OpenSSLiOS.xcframework"

xcodebuild -create-xcframework \
  -library "${BUILD_ROOT}/combined/libMongoCDriver-device.a" \
  -headers "${DRIVER_HEADERS}" \
  -library "${BUILD_ROOT}/combined/libMongoCDriver-simulator.a" \
  -headers "${DRIVER_HEADERS}" \
  -output "${VENDOR_ROOT}/MongoCDriver.xcframework"

xcodebuild -create-xcframework \
  -framework "${OPENSSL_ROOT}/OpenSSL.xcframework/ios-arm64/OpenSSL.framework" \
  -framework "${OPENSSL_ROOT}/OpenSSL.xcframework/ios-arm64_x86_64-simulator/OpenSSL.framework" \
  -output "${VENDOR_ROOT}/OpenSSLiOS.xcframework"

echo "Native iOS driver frameworks are ready in ${VENDOR_ROOT}."
