#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/USDZTextureAI/AdapterTests"
TASK_DEVELOPER="$(xcode-select -p)/Platforms/MacOSX.platform/Developer"
mkdir -p "$TASK_BUILD/AdapterTests.xctest/Contents/MacOS"
cd "$TASK_ROOT"
python3 - "$TASK_BUILD" <<'PY'
import sys,pathlib,plistlib
p=pathlib.Path(sys.argv[1])/'AdapterTests.xctest/Contents/Info.plist'
p.write_bytes(plistlib.dumps(dict(CFBundleExecutable='AdapterTests',CFBundlePackageType='BNDL',CFBundleIdentifier='local.forma.usdz-texture-adapter-tests')))
PY
xcrun swiftc -O -swift-version 5 -parse-as-library -emit-library -emit-module -enable-testing \
  -module-name Forma -target arm64-apple-macos15.0 -emit-module-path "$TASK_BUILD/Forma.swiftmodule" \
  Forma/Core/ProcessingControl.swift Forma/Core/USDZTextureRestorationAdapter.swift -o "$TASK_BUILD/libForma.dylib"
xcrun swiftc -O -swift-version 5 -parse-as-library -emit-library -module-name USDZTextureAdapterTests \
  -target arm64-apple-macos15.0 -I "$TASK_BUILD" -I "$TASK_DEVELOPER/usr/lib" -F "$TASK_DEVELOPER/Library/Frameworks" \
  -L "$TASK_BUILD" -L "$TASK_DEVELOPER/usr/lib" -lForma -framework XCTest \
  -Xlinker -rpath -Xlinker "$TASK_BUILD" -Xlinker -rpath -Xlinker "$TASK_DEVELOPER/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$TASK_DEVELOPER/usr/lib" Tests/USDZTextureRestorationAdapterTests.swift \
  -o "$TASK_BUILD/AdapterTests.xctest/Contents/MacOS/AdapterTests"
exec xcrun xctest "$TASK_BUILD/AdapterTests.xctest"
