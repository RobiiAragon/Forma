#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/GaussianCameraPose/acceptance-build"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun swiftc -O -parse-as-library -enable-testing -emit-library -emit-module -module-name Forma \
    Forma/Core/RGBDDataset.swift Forma/Core/GaussianViewpoint.swift \
    -emit-module-path "$TASK_BUILD/Forma.swiftmodule" -o "$TASK_BUILD/libForma.dylib"
xcrun swiftc -O -parse-as-library -I "$TASK_BUILD" -L "$TASK_BUILD" -lForma \
    Tools/verify_gaussian_viewpoint.swift -o "$TASK_BUILD/verify-gaussian-viewpoint"
export DYLD_LIBRARY_PATH="$TASK_BUILD${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec "$TASK_BUILD/verify-gaussian-viewpoint" "$@"
