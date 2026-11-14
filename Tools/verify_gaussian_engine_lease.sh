#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASK_BUILD="$TASK_ROOT/build/Research/GaussianEngineGate"
mkdir -p "$TASK_BUILD"
xcrun clang++ -std=c++17 -O2 -pthread -I "$TASK_ROOT/Vendor/Msplat/core/include" \
    "$TASK_ROOT/Tools/verify_gaussian_engine_lease.cpp" -o "$TASK_BUILD/verify-engine-lease"
exec "$TASK_BUILD/verify-engine-lease"
