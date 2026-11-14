#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/USDZModelRestoration"
TASK_DEVELOPER="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
mkdir -p "$TASK_BUILD/RestorationTests.xctest/Contents/MacOS"
cd "$TASK_ROOT"
python3 - "$TASK_BUILD" <<'PY'
import sys,pathlib,plistlib
p=pathlib.Path(sys.argv[1])/'RestorationTests.xctest/Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleExecutable='RestorationTests',CFBundlePackageType='BNDL',CFBundleIdentifier='local.forma.usdz-model-restoration-tests')))
PY
xcrun swiftc -O -swift-version 5 -parse-as-library -emit-library -emit-module -enable-testing \
 -module-name Forma -target arm64-apple-macos15.0 -emit-module-path "$TASK_BUILD/Forma.swiftmodule" \
 Forma/Core/ScanModels.swift Forma/Core/RGBDDataset.swift Forma/Core/COLMAPDatasetExporter.swift Forma/Core/MeshExporter.swift \
 Forma/Core/ProcessingControl.swift Forma/Core/CooperativeFileIO.swift Forma/Core/ScanStore.swift Forma/Core/PendingScanRecovery.swift \
 Forma/Core/TextureAssetInventory.swift Forma/Core/USDZTextureRestorationAdapter.swift Forma/Core/StoredUSDZArchive.swift \
 Forma/Core/LocalAITextureEnhancer.swift Forma/Core/LocalAIModelRestoration.swift -o "$TASK_BUILD/libForma.dylib"
xcrun swiftc -O -swift-version 5 -parse-as-library -emit-library -module-name LocalAIModelRestorationTests \
 -target arm64-apple-macos15.0 -I "$TASK_BUILD" -I "$TASK_DEVELOPER/usr/lib" -F "$TASK_DEVELOPER/Library/Frameworks" \
 -L "$TASK_BUILD" -L "$TASK_DEVELOPER/usr/lib" -lForma -framework XCTest \
 -Xlinker -rpath -Xlinker "$TASK_BUILD" -Xlinker -rpath -Xlinker "$TASK_DEVELOPER/Library/Frameworks" \
 -Xlinker -rpath -Xlinker "$TASK_DEVELOPER/usr/lib" Tests/LocalAIModelRestorationTests.swift \
 -o "$TASK_BUILD/RestorationTests.xctest/Contents/MacOS/RestorationTests"
export FORMA_TEST_RESTORER_URL="${FORMA_TEST_RESTORER_URL:-$TASK_ROOT/Forma/Resources/RealESRGAN_general_522_fp16.mlpackage}"
exec xcrun xctest "$TASK_BUILD/RestorationTests.xctest"
