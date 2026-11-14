#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Vendor/Msplat"
OUTPUT="$SOURCE/Build"
CMAKE="${FORMA_CMAKE_PATH:-cmake}"
mkdir -p "$OUTPUT/headers"
for PLATFORM in iphoneos iphonesimulator; do
    BUILD="$OUTPUT/$PLATFORM"
    "$CMAKE" -S "$SOURCE" -B "$BUILD" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$PLATFORM" --show-sdk-path)" \
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
        -DMSPLAT_METAL_SDK="$PLATFORM"
    "$CMAKE" --build "$BUILD" --target msplat_core metallib -j 4
done
cp "$SOURCE/core/include/forma_gaussian.h" "$OUTPUT/headers/"
cp "$SOURCE/core/include/msplat_c_api.h" "$OUTPUT/headers/"
cat > "$OUTPUT/headers/module.modulemap" <<'MAP'
module FormaGaussianCore {
    header "forma_gaussian.h"
    header "msplat_c_api.h"
    export *
}
MAP
rm -rf "$OUTPUT/MsplatCore.xcframework"
xcodebuild -create-xcframework \
    -library "$OUTPUT/iphoneos/libmsplat_core.a" -headers "$OUTPUT/headers" \
    -library "$OUTPUT/iphonesimulator/libmsplat_core.a" -headers "$OUTPUT/headers" \
    -output "$OUTPUT/MsplatCore.xcframework"
cp "$OUTPUT/iphoneos/default.metallib" "$OUTPUT/msplat-ios.metallib"
cp "$OUTPUT/iphonesimulator/default.metallib" "$OUTPUT/msplat-simulator.metallib"
cp "$OUTPUT/msplat-ios.metallib" "$ROOT/Forma/Resources/msplat-ios.metallib"
cp "$OUTPUT/msplat-simulator.metallib" "$ROOT/Forma/Resources/msplat-simulator.metallib"
python3 "$ROOT/scripts/verify_msplat_bundle.py" --record
echo "Built $OUTPUT/MsplatCore.xcframework and per-platform metallibs"
