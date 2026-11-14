#!/bin/bash
set -euo pipefail
FORMA_BENCH_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FORMA_BENCH_TMP="$(mktemp -d "${TMPDIR:-/tmp}/forma-viewer-benchmark.XXXXXX")"
trap 'rm -rf "$FORMA_BENCH_TMP"' EXIT
xcrun swiftc -O -whole-module-optimization \
    "$FORMA_BENCH_ROOT/Forma/Core/GaussianAsset.swift" \
    "$FORMA_BENCH_ROOT/Forma/Core/GaussianDepthOrder.swift" \
    "$FORMA_BENCH_ROOT/Forma/Core/MeshPreviewPreparation.swift" \
    "$FORMA_BENCH_ROOT/scripts/benchmark_viewer.swift" \
    -o "$FORMA_BENCH_TMP/benchmark"
"$FORMA_BENCH_TMP/benchmark" "$@"
