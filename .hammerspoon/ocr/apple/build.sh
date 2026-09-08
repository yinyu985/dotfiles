#!/bin/zsh

set -eu

SCRIPT_DIR=${0:A:h}
BUILD_PATH=$(mktemp "$SCRIPT_DIR/.visionocr.XXXXXX")
trap 'rm -f "$BUILD_PATH"' EXIT

xcrun swiftc -O \
  -target "$(uname -m)-apple-macosx12.0" \
  -framework Vision \
  -framework Foundation \
  -framework ImageIO \
  "$SCRIPT_DIR/visionocr.swift" \
  -o "$BUILD_PATH"

# Replace atomically: a failed build never damages the working helper.
chmod 755 "$BUILD_PATH"
mv -f "$BUILD_PATH" "$SCRIPT_DIR/visionocr"

print "built $SCRIPT_DIR/visionocr"
