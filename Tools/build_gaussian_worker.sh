#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/build/GaussianDesktopWorker}"
CMAKE="${FORMA_CMAKE_PATH:-cmake}"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
DEPENDENCIES=()
for NAME in nlohmann_json nanoflann cli11; do
    CACHE="$ROOT/Vendor/Msplat/Build/iphoneos/_deps/${NAME}-src"
    if [ -d "$CACHE" ]; then
        UPPER="$(echo "$NAME" | tr '[:lower:]' '[:upper:]')"
        DEPENDENCIES+=("-DFETCHCONTENT_SOURCE_DIR_${UPPER}=$CACHE")
    fi
done
"$CMAKE" -S "$ROOT/Vendor/Msplat" -B "$OUTPUT/native" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DMSPLAT_METAL_SDK=macosx -DMSPLAT_BUILD_TESTS=OFF "${DEPENDENCIES[@]}"
"$CMAKE" --build "$OUTPUT/native" --target msplat_core metallib -j 4
xcrun clang++ -O2 -std=c++17 -arch arm64 -mmacosx-version-min=15.0 \
    -I "$ROOT/Vendor/Msplat/core/include" "$ROOT/Tools/FormaGaussianWorker.mm" \
    "$OUTPUT/native/libmsplat_core.a" -framework Foundation -framework Metal \
    -framework MetalKit -framework MetalPerformanceShaders -framework ImageIO \
    -framework CoreGraphics -lz -o "$OUTPUT/FormaGaussianWorker"
codesign --force --sign - --timestamp=none "$OUTPUT/FormaGaussianWorker"
cp "$OUTPUT/native/default.metallib" "$OUTPUT/msplat-macos.metallib"
mkdir -p "$OUTPUT/Licenses"
cp "$ROOT/Vendor/Msplat/LICENSE" "$OUTPUT/Licenses/msplat-Apache-2.0.txt"
for LICENSE in \
    "$ROOT/Vendor/Msplat/Build/iphoneos/_deps/nlohmann_json-src/LICENSE.MIT" \
    "$ROOT/Vendor/Msplat/Build/iphoneos/_deps/nanoflann-src/COPYING"; do
    if [ -f "$LICENSE" ]; then cp "$LICENSE" "$OUTPUT/Licenses/$(basename "$(dirname "$LICENSE")")-$(basename "$LICENSE")"; fi
done
python3 "$ROOT/Tools/verify_gaussian_worker.py" --record --output "$OUTPUT"
echo "Built Apple Silicon worker: $OUTPUT/FormaGaussianWorker"
echo "Matching macOS shaders: $OUTPUT/msplat-macos.metallib"
