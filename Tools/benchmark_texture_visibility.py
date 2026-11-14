#!/usr/bin/env python3
"""CPU visibility/selection comparison; never re-encodes or modifies source scans.

Builds research-only copies of the real baker with two explicit changes: evaluate
only deterministic ROI faces (the FULL mesh remains the visibility context), and
stop before photometry/atlas export after writing diagnostic assignments. The
selection/coherence math and BVH are unchanged in each compared source version.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time
import zlib


PROBE = r'''
import Foundation
@main struct VisibilityProbe {
    static func main() throws {
        let args = CommandLine.arguments
        let mesh = try JSONDecoder().decode(MeshSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let dataset = URL(fileURLWithPath: args[2])
        let frames = try RGBDDatasetManifest.load(from: dataset).frames
        _ = try LiDARTextureBaker.bake(mesh: mesh, keyframes: frames, datasetDirectory: dataset,
                                      outputDirectory: URL(fileURLWithPath: args[3]))
    }
}
'''

DIAGNOSTICS = r'''
        var unsafeFaces: [Int] = []
        var unsafeSamples = [Int](repeating: 0, count: 7)
        if let visibility {
            for face in benchmarkFaces where assignments[face] >= 0 {
                let offset = face * 3
                let a = mesh.vertices[Int(mesh.triangles[offset])]
                let b = mesh.vertices[Int(mesh.triangles[offset + 1])]
                let c = mesh.vertices[Int(mesh.triangles[offset + 2])]
                let camera = frames[assignments[face]]
                var unsafe = false
                for (index, point) in [a,b,c,faces[face].center,(a+b)*0.5,(b+c)*0.5,(c+a)*0.5].enumerated() {
                    if visibility.isOccluded(from: camera.center, to: point, excludingFace: face) {
                        unsafeSamples[index] += 1; unsafe = true
                    }
                }
                if unsafe { unsafeFaces.append(face) }
            }
        }
        let report: [String: Any] = [
            "scope": "CPU selection/coherence diagnostic ROI, full original mesh visibility context; no atlas or photometric export",
            "meshFaceCount": faces.count, "evaluatedFaces": benchmarkFaces,
            "frameCount": frames.count, "selectionSeconds": selectionSeconds,
            "coherenceSeconds": coherenceSeconds, "boundaryEdgesBefore": coherence.before,
            "boundaryEdgesAfter": coherence.after, "coherenceReassignedFaces": coherence.changed,
            "texturedFaces": benchmarkFaces.filter { assignments[$0] >= 0 }.count,
            "selectedFrameIDs": benchmarkFaces.map { assignments[$0] < 0 ? "" : frames[assignments[$0]].record.id },
            "selectedRGBFiles": benchmarkFaces.map { assignments[$0] < 0 ? "" : frames[assignments[$0]].record.rgbFile },
            "unsafeFaceIDs": unsafeFaces, "occludedSampleCounts": unsafeSamples,
            "originalBestScores": benchmarkFaces.map { scores[$0] },
            "usedSourceCount": Set(assignments.filter { $0 >= 0 }).count]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDirectory.appendingPathComponent("selection.json"), options: .atomic)
        return LiDARTextureBakeResult(objURL: finalOBJ, materialURL: finalMTL, textureURLs: [],
            texturedFaceCount: benchmarkFaces.filter { assignments[$0] >= 0 }.count,
            unobservedFaceCount: benchmarkFaces.filter { assignments[$0] < 0 }.count)
'''


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as source:
        for data in iter(lambda: source.read(1024 * 1024), b''):
            value.update(data)
    return value.hexdigest()


def fixture(root):
    root.mkdir()
    dataset = root / 'dataset'
    (dataset / 'images').mkdir(parents=True)
    def png(path, color):
        def chunk(kind, data):
            return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
        data = (b'\0' + bytes(color) * 128) * 128
        path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 128, 128, 8, 2, 0, 0, 0))
                         + chunk(b'IDAT', zlib.compress(data)) + chunk(b'IEND', b''))
    png(dataset / 'images/preferred-occluded.png', (180, 60, 40))
    png(dataset / 'images/alternative-visible.png', (40, 180, 60))
    (dataset / 'depth.f32').write_bytes(struct.pack('<f', 2) * (16 * 16))
    frames = []
    for index, (name, x, focal) in enumerate((('preferred-occluded', 0, 128), ('alternative-visible', .3, 124))):
        frames.append(dict(id=name, timestamp=index + 1, rgbFile='images/' + name + '.png', imageWidth=128, imageHeight=128,
            cameraToWorld=[1,0,0,0,0,1,0,0,0,0,1,0,x,0,0,1], intrinsics=[focal,0,0,0,focal,0,63.5,63.5,1],
            depthFile='depth.f32', depthWidth=16, depthHeight=16, source='authored-fixture'))
    (dataset / 'dataset.json').write_text(json.dumps(dict(schemaVersion=1, createdAt=0, units='meters',
        matrixLayout='columnMajor', cameraConvention='ARKit camera -Z forward, +Y up', frames=frames)))
    # A narrow foreground triangle crosses only the lower-edge midpoint ray.
    # Its 4 cm offset remains inside the depth raster's existing 5 cm tolerance.
    mesh = dict(vertices=[[-.6,-.4,-2],[.6,-.4,-2],[0,.6,-2],
                          [-.0025,-.41,-1.96],[.0025,-.41,-1.96],[0,-.38,-1.96]], triangles=[0,1,2,3,4,5])
    (root / 'malla.json').write_text(json.dumps(mesh))
    return root / 'malla.json', dataset


def instrument(source, maximum_faces):
    if source.count('        let faces = faceGeometry(mesh)') != 1:
        raise ValueError('Baker instrumentation anchor changed')
    source = source.replace('        let faces = faceGeometry(mesh)', '''        let faces = faceGeometry(mesh)
        let benchmarkFaces: [Int]
        if faces.count <= MAXIMUM_FACES { benchmarkFaces = Array(faces.indices) }
        else {
            // 64 adjacent faces in each distributed block preserve local seams.
            let blocks = max(1, MAXIMUM_FACES / 64)
            benchmarkFaces = (0..<blocks).flatMap { block in
                let start = block * (faces.count - 64) / max(1, blocks - 1)
                return Array(start..<min(faces.count, start + 64))
            }
        }'''.replace('MAXIMUM_FACES', str(maximum_faces)))
    if source.count('            for faceIndex in faces.indices {') != 1:
        raise ValueError('Selection loop anchor changed')
    source = source.replace('            for faceIndex in faces.indices {', '            for faceIndex in benchmarkFaces {')
    anchor = '        let usedFrames = Set(assignments.filter { $0 >= 0 }).sorted()'
    if source.count(anchor) != 1:
        raise ValueError('Diagnostic stop anchor changed')
    return source.replace(anchor, DIAGNOSTICS + '\n' + anchor)


def run(repo, source, label, root, mesh, dataset, maximum_faces):
    build = root / ('build-' + label)
    build.mkdir()
    copy = build / 'LiDARTextureBaker.swift'
    copy.write_text(instrument(source.read_text(), maximum_faces))
    main = build / 'main.swift'
    main.write_text(PROBE)
    executable = build / 'probe'
    common = ['ScanModels.swift', 'RGBDDataset.swift', 'ProcessingControl.swift', 'TextureChartBuilder.swift',
              'TextureAtlasBuilder.swift', 'PhotometricHarmonizer.swift']
    command = ['xcrun', 'swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos15.0']
    command += [str(repo / 'Forma/Core' / name) for name in common] + [str(copy), str(main), '-o', str(executable)]
    with (build / 'compile.log').open('w') as log:
        subprocess.run(command, check=True, stdout=log, stderr=log)
    output = root / label
    with (build / 'run.log').open('w') as log:
        subprocess.run([str(executable), str(mesh), str(dataset), str(output)], check=True, stdout=log, stderr=log)
    return json.loads((output / 'selection.json').read_text())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-source', type=Path, required=True)
    parser.add_argument('--candidate-source', type=Path)
    parser.add_argument('--mesh', type=Path)
    parser.add_argument('--dataset', type=Path)
    parser.add_argument('--maximum-faces', type=int, default=4096, help='Research ROI only; never a production quota')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    root = args.output.resolve(); root.mkdir(parents=True, exist_ok=False)
    if (args.mesh is None) != (args.dataset is None):
        parser.error('--mesh and --dataset must be supplied together')
    if args.maximum_faces <= 0:
        parser.error('--maximum-faces must be positive')
    mesh, dataset = (args.mesh.resolve(), args.dataset.resolve()) if args.mesh else fixture(root / 'authored-fixture')
    # Hash all referenced inputs before/after. No scan source is ever written.
    manifest = json.loads((dataset / 'dataset.json').read_text())
    paths = {mesh, dataset / 'dataset.json'}
    for frame in manifest['frames']:
        paths.update(dataset / frame[name] for name in ('rgbFile', 'depthFile', 'confidenceFile') if frame.get(name))
    before = {str(path): digest(path) for path in sorted(paths)}
    start = time.monotonic()
    baseline = run(repo, args.baseline_source.resolve(), 'baseline', root, mesh, dataset, args.maximum_faces)
    candidate_source = (args.candidate_source or repo / 'Forma/Core/LiDARTextureBaker.swift').resolve()
    candidate = run(repo, candidate_source, 'candidate', root, mesh, dataset, args.maximum_faces)
    assert baseline['evaluatedFaces'] == candidate['evaluatedFaces']
    after = {str(path): digest(path) for path in sorted(paths)}
    assert before == after, 'Original sources changed'
    changes = [face for face, old, new in zip(baseline['evaluatedFaces'], baseline['selectedFrameIDs'], candidate['selectedFrameIDs']) if old != new]
    compact = dict(scope=baseline['scope'], status='passed', fixture='same preserved room ROI' if args.mesh else 'authored thin edge occluder',
        baselineSourceSHA256=digest(args.baseline_source), candidateSourceSHA256=digest(candidate_source),
        meshFaceCount=baseline['meshFaceCount'], evaluatedFaceCount=len(baseline['evaluatedFaces']), frameCount=baseline['frameCount'],
        baseline={k: baseline[k] for k in ('texturedFaces', 'usedSourceCount', 'selectionSeconds', 'coherenceSeconds', 'boundaryEdgesAfter', 'occludedSampleCounts')},
        candidate={k: candidate[k] for k in ('texturedFaces', 'usedSourceCount', 'selectionSeconds', 'coherenceSeconds', 'boundaryEdgesAfter', 'occludedSampleCounts')},
        baselineMeshOcclusionViolationFaces=len(baseline['unsafeFaceIDs']), candidateMeshOcclusionViolationFaces=len(candidate['unsafeFaceIDs']),
        changedFaceIDs=changes, sourceFilesHashed=len(before), sourceSHA256Unchanged=True, noSourceResizing=True,
        noGeometryChanges=True, GPUUsed=False, elapsedSeconds=time.monotonic()-start)
    if not args.mesh:
        assert baseline['selectedFrameIDs'][0] == 'preferred-occluded'
        assert candidate['selectedFrameIDs'][0] == 'alternative-visible'
        assert 0 in baseline['unsafeFaceIDs'] and 0 not in candidate['unsafeFaceIDs']
        compact['knownOccluderAtEdgeMidpointSelectsVisibleAlternative'] = True
    (root / 'input-sha256.json').write_text(json.dumps(before, indent=2) + '\n')
    (root / 'measurements.json').write_text(json.dumps(compact, indent=2) + '\n')
    print(json.dumps(compact, indent=2))


if __name__ == '__main__':
    main()
