#!/bin/bash
set -euo pipefail
umask 077
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Usage: Tools/verify_hybrid_hardware.sh --device UDID --xctestrun BASE [--output DIRECTORY] [--usb-local-port PORT] [--usb-device-port PORT]' \
    'Compiles only a Mac command-line harness, opens a temporary Bonjour receiver and waits.' \
    'Writes a private derived xctestrun and prints the separate device-test command.' \
    'Does not build/install/launch a device app. iPhone test bundle must first contain HybridPhysicalTransportTests.'
  exit 0
fi
task_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$task_dir"
mkdir -p build/Tools
xcrun swiftc -O -parse-as-library \
  Forma/Core/HybridTransfer.swift Forma/Core/ScanModels.swift Forma/Core/RGBDDataset.swift \
  Forma/Core/ScanStore.swift Forma/Core/MeshExporter.swift Forma/Core/COLMAPDatasetExporter.swift \
  Forma/Core/ProcessingControl.swift Forma/Core/CooperativeFileIO.swift Forma/Core/PendingScanRecovery.swift \
  Tools/verify_hybrid_hardware.swift -o build/Tools/verify_hybrid_hardware
exec build/Tools/verify_hybrid_hardware "$@"
