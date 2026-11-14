#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/GaussianDesktopController"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
    Forma/Core/ScanModels.swift Forma/Core/RGBDDataset.swift \
    Forma/Core/COLMAPDatasetExporter.swift Forma/Core/MeshExporter.swift \
    Forma/Core/ProcessingControl.swift Forma/Core/CooperativeFileIO.swift \
    Forma/Core/ScanStore.swift Forma/Core/PendingScanRecovery.swift \
    Mac/DesktopGaussianRuntimeVault.swift Mac/DesktopGaussian.swift Tools/verify_desktop_gaussian.swift \
    -o "$TASK_BUILD/verify-desktop-gaussian"
exec "$TASK_BUILD/verify-desktop-gaussian" "$@"
