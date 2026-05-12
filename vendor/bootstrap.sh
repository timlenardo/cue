#!/usr/bin/env bash
# Fetch and extract sherpa-onnx iOS XCFrameworks into vendor/.
# See vendor/README.md for context.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
VERSION="v1.13.1"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${VERSION}/sherpa-onnx-${VERSION}-ios-no-tts.tar.bz2"
TMP=$(mktemp -d)

echo "Downloading sherpa-onnx ${VERSION} ios-no-tts..."
curl -fL -o "$TMP/sherpa.tar.bz2" "$URL"

echo "Extracting..."
tar -xjf "$TMP/sherpa.tar.bz2" -C "$TMP"

rm -rf "$SCRIPT_DIR/sherpa-onnx.xcframework" "$SCRIPT_DIR/onnxruntime.xcframework"
mv "$TMP/build-ios-no-tts/sherpa-onnx.xcframework" "$SCRIPT_DIR/"
mv "$TMP/build-ios-no-tts/ios-onnxruntime/1.17.1/onnxruntime.xcframework" "$SCRIPT_DIR/"

rm -rf "$TMP"
echo "Done. Contents:"
ls -la "$SCRIPT_DIR"
