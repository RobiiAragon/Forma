#!/bin/bash
# Build-time only. Requires the already fetched official sources/dependencies;
# never downloads code or runs a compiler from the installed application.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${FORMA_TEXTURE_SOURCE:-$ROOT/build/Tools/mvs-texturing-source}"
BUILD="${FORMA_TEXTURE_BUILD:-$ROOT/build/Tools/mvs-texturing-build}"
OUTPUT="${1:-$ROOT/build/PhotographicTextureWorker}"
CMAKE="${FORMA_CMAKE_PATH:-cmake}"
if [[ "$(uname -m)" != arm64 ]]; then
    echo 'This local build is configured for Apple Silicon; no x86 binary is advertised.' >&2
    exit 1
fi
for ITEM in "$SOURCE/CMakeLists.txt" "$SOURCE/elibs/mve/libs/mve/Makefile" "$SOURCE/elibs/eigen/Eigen/Core" "$SOURCE/elibs/mapmap/mapmap/header/mapmap.h"; do
    if [[ ! -f "$ITEM" ]]; then
        echo "Required local source missing: $ITEM. No download was attempted." >&2
        exit 1
    fi
done
if ! git -C "$SOURCE" apply --reverse --check "$ROOT/Tools/mvs-texturing-forma.patch" >/dev/null 2>&1; then
    if git -C "$SOURCE" diff --quiet && git -C "$SOURCE" apply --check "$ROOT/Tools/mvs-texturing-forma.patch"; then
        git -C "$SOURCE" apply "$ROOT/Tools/mvs-texturing-forma.patch"
    else
        echo 'MVE source does not match the reviewed Forma patch; refusing an ambiguous worker build.' >&2
        exit 1
    fi
fi
"$CMAKE" -S "$SOURCE" -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    '-DCMAKE_CXX_FLAGS=-DHOST_BYTEORDER_LE -Wno-deprecated-declarations -Xpreprocessor -fopenmp -I/opt/homebrew/opt/libomp/include' \
    '-DCMAKE_EXE_LINKER_FLAGS=-L/opt/homebrew/opt/libomp/lib -lomp' \
    -DOpenMP_C_FLAGS='-Xclang -fopenmp' -DOpenMP_CXX_FLAGS='-Xclang -fopenmp' \
    -DOpenMP_C_LIB_NAMES=omp -DOpenMP_CXX_LIB_NAMES=omp \
    -DOpenMP_omp_LIBRARY=/opt/homebrew/opt/libomp/lib/libomp.dylib
"$CMAKE" --build "$BUILD" --target texrecon -j "${FORMA_BUILD_JOBS:-2}"
python3 "$ROOT/Tools/package_texture_worker.py" --source "$SOURCE" \
    --executable "$BUILD/apps/texrecon/texrecon" --output "$OUTPUT"
python3 "$ROOT/Tools/verify_texture_worker.py" --worker "$OUTPUT/texrecon" \
    --output "$OUTPUT-verification"
python3 "$ROOT/Tools/package_texture_worker.py" --verify --output "$OUTPUT"
echo "Built and verified self-contained local worker: $OUTPUT"
