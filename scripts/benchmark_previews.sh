#!/bin/bash
# Local authored geometry/images only. Does not launch apps or access a device.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/build/PreviewBenchmark-Reproduction}"
mkdir -p "$OUTPUT"
cd "$ROOT"
swiftc -O -D CANDIDATE -parse-as-library \
    Tools/PerformanceBaselines/TexturePreviewProxy-20261020.swift \
    Forma/Core/TexturePreviewProxy.swift Tools/benchmark_preview_reuse.swift \
    -o "$OUTPUT/preview-benchmark"
"$OUTPUT/preview-benchmark" "$OUTPUT/authored-fixture" > "$OUTPUT/preview-interleaved.json"
python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import sys
source=Path('Forma/Core/TextureAssetInventory.swift').read_text().replace('TextureAssetInventory','MeasuredTextureAssetInventory')
source=source.replace('try String(contentsOf: modelURL, encoding: .utf8)','try BaselineReads.text(modelURL)').replace('try String(contentsOf: mtl, encoding: .utf8)','try BaselineReads.text(mtl)').replace('CGImageSourceCreateWithURL(url as CFURL,','BaselineReads.image(url as CFURL,')
(Path(sys.argv[1])/'MeasuredInventory.swift').write_text(source)
PY
swiftc -O -D INVENTORY_BENCHMARK -D INVENTORY_CANDIDATE -parse-as-library \
    Tools/PerformanceBaselines/TexturePreviewProxy-20261020.swift \
    Tools/PerformanceBaselines/TextureAssetInventory-20261020.swift \
    "$OUTPUT/MeasuredInventory.swift" Tools/benchmark_preview_reuse.swift \
    -o "$OUTPUT/inventory-benchmark"
"$OUTPUT/inventory-benchmark" "$OUTPUT/authored-fixture" > "$OUTPUT/inventory-interleaved.json"
python3 - "$OUTPUT" <<'PY'
from pathlib import Path
import json,statistics,sys
root=Path(sys.argv[1])
for name in ['preview-interleaved.json','inventory-interleaved.json']:
    report=json.loads((root/name).read_text())
    print(name)
    for variant in ['baseline','candidate']:
        rows=[r for r in report['runs'] if r['variant']==variant]
        print(variant, 'median milliseconds',statistics.median(r['seconds'] for r in rows)*1000,rows[0]['resourceOperations'])
    key='artifactsSHA256' if 'preview' in name else 'inventory'
    assert len({json.dumps(r[key],sort_keys=True) for r in report['runs']})==1
    if 'sourceUnchanged' in report: assert report['sourceUnchanged']
print('Identical outputs verified; timings concern these stages only.')
PY
