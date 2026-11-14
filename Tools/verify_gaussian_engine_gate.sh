#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/GaussianEngineGate"
mkdir -p "$TASK_BUILD/GaussianEngineGateTests.xctest/Contents/MacOS"
cd "$TASK_ROOT"
python3 - "$TASK_BUILD" <<'PY'
import sys,pathlib,plistlib
out=pathlib.Path(sys.argv[1])
s=pathlib.Path('Forma/Core/GaussianTrainerService.swift').read_text()
(out/'GaussianTrainingControl.swift').write_text('import Foundation\n'+s[s.index('struct GaussianSessionPauseState'):])
(out/'GaussianEngineGateTests.xctest/Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='GaussianEngineGateTests',CFBundlePackageType='BNDL',CFBundleIdentifier='local.forma.gaussian-engine-gate-tests')))
PY
TASK_DEVELOPER="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
xcrun swiftc -O -swift-version 5 -parse-as-library -emit-library -emit-module -enable-testing \
    -module-name Forma -target arm64-apple-macos15.0 -emit-module-path "$TASK_BUILD/Forma.swiftmodule" \
    Forma/Core/ProcessingControl.swift Forma/Core/MobileProcessingPolicy.swift Forma/Core/GaussianRecovery.swift \
    Forma/Core/GaussianEngineGate.swift "$TASK_BUILD/GaussianTrainingControl.swift" \
    -o "$TASK_BUILD/libForma.dylib"
xcrun swiftc -O -swift-version 5 -parse-as-library -emit-library -module-name GaussianEngineGateTests \
    -target arm64-apple-macos15.0 -I "$TASK_BUILD" -I "$TASK_DEVELOPER/usr/lib" -F "$TASK_DEVELOPER/Library/Frameworks" \
    -L "$TASK_BUILD" -L "$TASK_DEVELOPER/usr/lib" -lForma -framework XCTest \
    -Xlinker -rpath -Xlinker "$TASK_BUILD" -Xlinker -rpath -Xlinker "$TASK_DEVELOPER/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$TASK_DEVELOPER/usr/lib" Tests/GaussianEngineGateTests.swift Tests/GaussianPacingTests.swift Tests/GaussianSessionTests.swift \
    -o "$TASK_BUILD/GaussianEngineGateTests.xctest/Contents/MacOS/GaussianEngineGateTests"
exec xcrun xctest "$TASK_BUILD/GaussianEngineGateTests.xctest"
