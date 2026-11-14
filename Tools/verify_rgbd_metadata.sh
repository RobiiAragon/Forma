#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/RGBDSensorMetadata"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
    Forma/Core/RGBDDataset.swift Tools/verify_rgbd_metadata.swift \
    -o "$TASK_BUILD/verify-rgbd-metadata"
exec "$TASK_BUILD/verify-rgbd-metadata" "$@"
