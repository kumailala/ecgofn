#!/bin/bash
# Build NEWLIB.dylib for iOS (device). Run this on macOS (or the GitHub Action).
set -e

OUT="${1:-NEWLIB.dylib}"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
FRAMEWORKS="-framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics"
FLAGS="-isysroot $SDK -fobjc-arc -O2 -Wall"

echo "SDK: $SDK"

# arm64  (iOS 11+, all 64-bit devices)
clang -dynamiclib -arch arm64  -miphoneos-version-min=11.0 $FLAGS $FRAMEWORKS \
      -install_name @executable_path/NEWLIB.dylib -o NEWLIB_arm64.dylib Tweak.m

# arm64e (A12+, iOS 12+)
clang -dynamiclib -arch arm64e -miphoneos-version-min=12.0 $FLAGS $FRAMEWORKS \
      -install_name @executable_path/NEWLIB.dylib -o NEWLIB_arm64e.dylib Tweak.m

lipo -create NEWLIB_arm64.dylib NEWLIB_arm64e.dylib -output "$OUT"
rm -f NEWLIB_arm64.dylib NEWLIB_arm64e.dylib

echo "== built =="
lipo -info "$OUT"
