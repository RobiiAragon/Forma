#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/HybridStatusQuery"
mkdir -p "$TASK_BUILD"
cd "$TASK_ROOT"
xcrun swiftc -O -parse-as-library \
    Forma/Core/ScanModels.swift Forma/Core/RGBDDataset.swift \
    Forma/Core/COLMAPDatasetExporter.swift Forma/Core/MeshExporter.swift \
    Forma/Core/ProcessingControl.swift Forma/Core/CooperativeFileIO.swift \
    Forma/Core/ScanStore.swift Forma/Core/PendingScanRecovery.swift \
    Forma/Core/HybridTransfer.swift Tools/query_hybrid_status.swift \
    -o "$TASK_BUILD/query-hybrid-status"
exec "$TASK_BUILD/query-hybrid-status" "$@"
