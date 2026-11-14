#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/RawTextureROIBenchmark"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
    Tools/benchmark_raw_texture_roi.swift -o "$TASK_BUILD/benchmark-raw-texture-roi"
exec "$TASK_BUILD/benchmark-raw-texture-roi" "$@"
