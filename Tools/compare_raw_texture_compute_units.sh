#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/RawTextureROIBenchmark"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun swiftc -O -D FORMA_RAW_TEXTURE_COMPUTE_COMPARISON -parse-as-library -target arm64-apple-macos15.0 \
    Tools/benchmark_raw_texture_roi.swift Tools/compare_raw_texture_compute_units.swift \
    -o "$TASK_BUILD/compare-raw-texture-compute-units"
exec "$TASK_BUILD/compare-raw-texture-compute-units" "$@"
