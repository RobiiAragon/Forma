#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$TASK_ROOT"
mkdir -p build/Research/HybridRemoteStore
python3 - "$@" <<'PYCODE'
import ast,subprocess,sys
from pathlib import Path
module=ast.parse(Path('scripts/generate_project.py').read_text())
shared=next(ast.literal_eval(n.value) for n in module.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='shared_names' for t in n.targets))
files=[str(Path('Forma/Core')/(name+'.swift')) for name in shared]
files += ['Mac/'+name+'.swift' for name in ['DesktopStore','DesktopRemoteControlLedger','DesktopHybridResultPackage','DesktopGaussianRuntimeVault','DesktopGaussian','DesktopLocalAI','DesktopLocalAIRecovery','LocalAIModelStore','DesktopPhotogrammetry','DesktopPhotogrammetryInput']]
output='build/Research/HybridRemoteStore/verify-desktop-hybrid-remote'
subprocess.run(['xcrun','swiftc','-O','-D','FORMA_HYBRID_REMOTE_HARNESS','-parse-as-library','-target','arm64-apple-macos15.0',*files,'Tools/verify_desktop_hybrid_gaussian.swift','Tools/verify_desktop_hybrid_remote.swift','-o',output],check=True)
raise SystemExit(subprocess.run([output,*sys.argv[1:]]).returncode)
PYCODE
