#!/bin/bash
set -euo pipefail

# Requires the Xcode command-line tools, macOS 15+ and a compatible Mac.
# Compiles only production Swift files; no app launch, Python, Comfy or download.
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$task_root/build/Research/LocalAI/repro-build"
mkdir -p "$task_build"
cd "$task_root"

xcrun swiftc -O -parse-as-library -enable-testing -emit-library -emit-module \
  -module-name FormaLocalAI \
  Forma/Core/ScanModels.swift \
  Forma/Core/RGBDDataset.swift \
  Forma/Core/COLMAPDatasetExporter.swift \
  Forma/Core/MeshExporter.swift \
  Forma/Core/ProcessingControl.swift \
  Forma/Core/CooperativeFileIO.swift \
  Forma/Core/ScanStore.swift \
  Forma/Core/PendingScanRecovery.swift \
  Forma/Core/TextureAssetInventory.swift \
  Forma/Core/USDZTextureRestorationAdapter.swift \
  Forma/Core/LocalAITextureEnhancer.swift \
  -emit-module-path "$task_build/FormaLocalAI.swiftmodule" \
  -o "$task_build/libFormaLocalAI.dylib"
xcrun swiftc -O -parse-as-library -I "$task_build" -L "$task_build" -lFormaLocalAI \
  Tools/verify_local_ai.swift -o "$task_build/verify-local-ai"

export DYLD_LIBRARY_PATH="$task_build${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
exec "$task_build/verify-local-ai" "$@"
