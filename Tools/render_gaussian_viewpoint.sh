#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/GaussianViewpointRender/build"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun swiftc -O -parse-as-library \
    Forma/Core/ScanModels.swift Forma/Core/RGBDDataset.swift \
    Forma/Core/COLMAPDatasetExporter.swift Forma/Core/MeshExporter.swift \
    Forma/Core/ProcessingControl.swift Forma/Core/CooperativeFileIO.swift \
    Forma/Core/ScanStore.swift Forma/Core/PendingScanRecovery.swift \
    Forma/Core/GaussianViewpoint.swift \
    Forma/Core/GaussianAsset.swift Forma/Core/GaussianDepthOrder.swift \
    Tools/render_gaussian_viewpoint.swift -o "$TASK_BUILD/render-gaussian-viewpoint"
exec "$TASK_BUILD/render-gaussian-viewpoint" "$@"
