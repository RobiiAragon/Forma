#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/DesktopGaussianLegacy"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun clang++ -std=c++17 -O2 -fobjc-arc -framework Foundation \
    Tools/fixture_desktop_gaussian_legacy.mm -o "$TASK_BUILD/synthetic-posix-worker"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
    Forma/Core/ScanModels.swift Forma/Core/RGBDDataset.swift \
    Forma/Core/COLMAPDatasetExporter.swift Forma/Core/MeshExporter.swift \
    Forma/Core/ProcessingControl.swift Forma/Core/CooperativeFileIO.swift \
    Forma/Core/ScanStore.swift Forma/Core/PendingScanRecovery.swift \
    Mac/DesktopGaussianRuntimeVault.swift Mac/DesktopGaussian.swift Tools/verify_desktop_gaussian_legacy.swift \
    -o "$TASK_BUILD/verify-desktop-gaussian-legacy"
exec "$TASK_BUILD/verify-desktop-gaussian-legacy" "$TASK_BUILD/synthetic-posix-worker" "$@"
