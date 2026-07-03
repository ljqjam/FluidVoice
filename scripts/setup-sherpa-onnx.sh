#!/bin/bash
# Downloads the sherpa-onnx prebuilt xcframeworks and repackages them for the
# local SPM package at ThirdParty/SherpaOnnxSPM.
#
# Why repackaging: both upstream xcframeworks ship a root-level
# Headers/module.modulemap; Xcode flattens every binary target's headers into
# one include/ directory, so the duplicate module.modulemap breaks the build
# ("Multiple commands produce"). The onnxruntime headers are never imported
# from Swift (the wrapper only imports the sherpa_onnx module), so its
# module.modulemap files are deleted.
#
# Run once after cloning (and again only if VERSION changes):
#   ./scripts/setup-sherpa-onnx.sh
set -euo pipefail

VERSION="1.13.2"
SHERPA_SHA256="62de3c1423a4f20516e8623858ee8c8d306af7ebb2a3737dc0600b1d4ee6aa4b"
ORT_SHA256="38bc65b3e6af3e6d99bc18a40f80bfb3e56ee1eedfa0d0a60feb1c97a2d06dee"
BASE_URL="https://github.com/willwade/sherpa-onnx-spm/releases/download/${VERSION}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARIES_DIR="${REPO_ROOT}/ThirdParty/SherpaOnnxSPM/Binaries"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

download_and_verify() {
  local name="$1" sha256="$2"
  local zip="${WORK_DIR}/${name}.xcframework.zip"
  echo "Downloading ${name}.xcframework.zip (${VERSION})..."
  curl -fL --retry 3 -o "${zip}" "${BASE_URL}/${name}.xcframework.zip"
  echo "${sha256}  ${zip}" | shasum -a 256 -c - >/dev/null
  unzip -q "${zip}" -d "${WORK_DIR}/${name}"
}

download_and_verify "sherpa-onnx" "${SHERPA_SHA256}"
download_and_verify "onnxruntime" "${ORT_SHA256}"

# Strip the conflicting modulemaps; Swift only imports the sherpa_onnx module.
find "${WORK_DIR}/onnxruntime" -name module.modulemap -delete

mkdir -p "${BINARIES_DIR}"
rm -rf "${BINARIES_DIR}/sherpa-onnx.xcframework" "${BINARIES_DIR}/onnxruntime.xcframework"
mv "${WORK_DIR}/sherpa-onnx/sherpa-onnx.xcframework" "${BINARIES_DIR}/"
# The onnxruntime zip nests the xcframework one directory deeper.
mv "${WORK_DIR}/onnxruntime/onnxruntime/onnxruntime.xcframework" "${BINARIES_DIR}/"

echo "OK: xcframeworks installed to ThirdParty/SherpaOnnxSPM/Binaries"
