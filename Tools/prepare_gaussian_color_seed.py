#!/usr/bin/env python3
"""Research-only photographic RGB initialization; all geometry/capture inputs stay read-only."""
import os
os.environ['OPENCV_OPENCL_RUNTIME'] = 'disabled'
os.environ['OPENBLAS_NUM_THREADS'] = '2'
os.environ['OMP_NUM_THREADS'] = '2'
from pathlib import Path
import argparse
import csv
import ctypes
import hashlib
import json
import resource
import subprocess
import sys
import tempfile
import time
import cv2
import numpy as np

cv2.ocl.setUseOpenCL(False)
cv2.setNumThreads(2)
REPO = Path(__file__).resolve().parent.parent
SCAN = Path.home() / 'Library/Application Support/FormaDesktop/Incoming/8CA53ED6-74E0-4AAB-9B13-6E562562081F'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2, sort_keys=True, allow_nan=False) + '\n')


def mm(a, b):
    # Explicit CPU contractions also provide a check independent of BLAS matmul.
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    require(np.isfinite(a).all() and np.isfinite(b).all(), 'Nonfinite matrix input')
    result = np.einsum('ik,kj->ij', a, b, optimize=False)
    require(np.isfinite(result).all(), 'Nonfinite matrix result')
    return result


def local(root, name):
    p = (root / name).resolve()
    require(p.is_relative_to(root.resolve()) and p.is_file(), 'Missing input or path escapes dataset: ' + str(name))
    return p


class Visibility:
    def __init__(self, library, vertices, triangles):
        self.lib = ctypes.CDLL(str(library))
        ptr = ctypes.c_void_p
        self.lib.seed_bvh_create.argtypes = [ptr, ctypes.c_size_t, ptr, ctypes.c_size_t]
        self.lib.seed_bvh_create.restype = ptr
        self.lib.seed_bvh_destroy.argtypes = [ptr]
        self.lib.seed_bvh_occluded.argtypes = [ptr, ptr, ptr, ctypes.c_size_t, ptr]
        self.lib.seed_bvh_occluded.restype = ctypes.c_int
        self.lib.seed_bvh_error.restype = ctypes.c_char_p
        v = np.ascontiguousarray(vertices, np.float64)
        t = np.ascontiguousarray(triangles, np.uint32).reshape((-1, 3))
        self.handle = self.lib.seed_bvh_create(v.ctypes.data, len(v), t.ctypes.data, len(t))
        require(bool(self.handle), 'Cannot build CPU BVH: ' + self.lib.seed_bvh_error().decode())

    def occluded(self, origin, points):
        origin, points = np.ascontiguousarray(origin, np.float64), np.ascontiguousarray(points, np.float64)
        result = np.zeros(len(points), np.uint8)
        require(self.lib.seed_bvh_occluded(self.handle, origin.ctypes.data, points.ctypes.data, len(points), result.ctypes.data) == 0,
                'CPU visibility failed: ' + self.lib.seed_bvh_error().decode())
        return result.astype(bool)

    def close(self):
        if self.handle:
            self.lib.seed_bvh_destroy(self.handle)
            self.handle = None


def build_visibility(output):
    source = REPO / 'Tools/gaussian_seed_visibility.cpp'
    binary = output / 'libGaussianSeedVisibility.dylib'
    command = ['xcrun', 'clang++', '-std=c++17', '-O3', '-dynamiclib', str(source), '-o', str(binary)]
    run = subprocess.run(command, text=True, capture_output=True)
    (output / 'visibility-build.log').write_text(run.stdout + run.stderr)
    require(run.returncode == 0, 'CPU BVH build failed; see visibility-build.log')
    write_json(output / 'visibility-build.json', dict(command=command, sourceSHA256=sha(source), binarySHA256=sha(binary)))
    (output / source.name).write_bytes(source.read_bytes())
    return binary


def read_points(path):
    lines = path.read_text().splitlines()
    rows = [line.split() for line in lines if line.strip() and not line.lstrip().startswith('#')]
    require(rows and all(len(row) >= 8 for row in rows), 'Invalid points3D rows')
    ids = np.asarray([int(row[0]) for row in rows], np.int64)
    points = np.asarray([[float(x) for x in row[1:4]] for row in rows], np.float64)
    colors = np.asarray([[int(x) for x in row[4:7]] for row in rows], np.int16)
    require(len(np.unique(ids)) == len(ids) and np.isfinite(points).all(), 'Duplicate ID or nonfinite point')
    require(np.all(colors == 128), 'This controlled arm requires the unchanged neutral-gray baseline')
    return lines, rows, ids, points


def normals_for_points(vertices, triangles, points):
    require(vertices.shape[1:] == (3,) and np.isfinite(vertices).all(), 'Invalid mesh vertices')
    triangles = triangles.reshape((-1, 3))
    require(len(triangles) and int(triangles.max()) < len(vertices), 'Invalid mesh indices')
    faces = np.cross(vertices[triangles[:, 1]] - vertices[triangles[:, 0]], vertices[triangles[:, 2]] - vertices[triangles[:, 0]])
    vertex_normals = np.zeros_like(vertices)
    np.add.at(vertex_normals, triangles.ravel(), np.repeat(faces, 3, axis=0))
    unique, inverse = np.unique(vertices.astype(np.float32), axis=0, return_inverse=True)
    aggregate = np.zeros((len(unique), 3), np.float64)
    np.add.at(aggregate, inverse, vertex_normals)
    lookup = {value.tobytes(): i for i, value in enumerate(unique)}
    indices = np.asarray([lookup.get(value.tobytes(), -1) for value in points.astype(np.float32)], np.int64)
    require(np.all(indices >= 0), 'A source point is not one of the original LiDAR mesh vertices')
    values = aggregate[indices]
    lengths = np.linalg.norm(values, axis=1)
    valid = lengths > 1e-8
    values[valid] /= lengths[valid, None]
    values[~valid] = 0
    return values, valid, len(unique)


def project(frame, points):
    pose = np.asarray(frame['cameraToWorld'], np.float64).reshape((4, 4), order='F')
    k = np.asarray(frame['intrinsics'], np.float64).reshape((3, 3), order='F')
    require(np.isfinite(pose).all() and np.isfinite(k).all() and k[0, 0] > 0 and k[1, 1] > 0, 'Invalid calibrated frame')
    inverse = np.linalg.inv(pose)
    q = mm(points, inverse[:3, :3].T) + inverse[:3, 3]
    q[:, 1:] *= -1
    z = q[:, 2]
    projected = mm(q, k.T)
    pixels = np.zeros((len(points), 2), np.float64)
    np.divide(projected[:, :2], z[:, None], out=pixels, where=z[:, None] > .001)
    width, height = frame['imageWidth'], frame['imageHeight']
    inside = (z > .001) & (pixels[:, 0] >= 0) & (pixels[:, 1] >= 0) & (pixels[:, 0] < width-1) & (pixels[:, 1] < height-1)
    return pixels, z, inside, pose[:3, 3], k


def depth_support(frame, pixels, z, depth, confidence):
    height, width = depth.shape
    require(depth.dtype == np.float32 and depth.shape == confidence.shape, 'Invalid depth/confidence raster')
    x = np.floor((pixels[:, 0] + .5) * width / frame['imageWidth']).astype(np.int64)
    y = np.floor((pixels[:, 1] + .5) * height / frame['imageHeight']).astype(np.int64)
    inside = (x >= 1) & (x < width-1) & (y >= 1) & (y < height-1)
    x, y = np.clip(x, 0, width-1), np.clip(y, 0, height-1)
    finite = np.isfinite(depth) & (depth > 0)
    kernel = np.ones((3, 3), np.uint8)
    valid_neighborhood = cv2.erode(finite.astype(np.uint8), kernel, borderType=cv2.BORDER_CONSTANT, borderValue=0).astype(bool)
    confidence_neighborhood = cv2.erode(confidence, kernel, borderType=cv2.BORDER_CONSTANT, borderValue=0)
    safe_depth = np.where(finite, depth, np.float32(0))
    minimum = cv2.erode(safe_depth, kernel)
    maximum = cv2.dilate(safe_depth, kernel)
    measured = safe_depth[y, x]
    tolerance = np.maximum(.03, measured * .025)
    residual = np.abs(z - measured)
    accepted = inside & valid_neighborhood[y, x] & (confidence_neighborhood[y, x] == 2)
    accepted &= (maximum[y, x] - minimum[y, x] <= tolerance) & (residual <= tolerance)
    return accepted, residual / tolerance, measured


def detail_quality(image, pixels):
    # Analysis only: same 1024px/0.35-floor idea as the baker. RGB remains native.
    height, width = image.shape[:2]
    scale = min(1., 1024 / max(width, height))
    thumb = cv2.resize(image, (round(width*scale), round(height*scale)), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(thumb, cv2.COLOR_BGR2GRAY).astype(np.float32)
    gradient = np.zeros_like(gray)
    gradient[1:-1, 1:-1] = (np.abs(gray[1:-1, 2:] - gray[1:-1, :-2]) + np.abs(gray[2:, 1:-1] - gray[:-2, 1:-1])) / 2
    gradient = cv2.blur(gradient, (3, 3), borderType=cv2.BORDER_REPLICATE)
    x = np.clip(np.floor((pixels[:, 0] + .5) * gray.shape[1] / width).astype(np.int64), 0, gray.shape[1]-1)
    y = np.clip(np.floor((pixels[:, 1] + .5) * gray.shape[0] / height).astype(np.int64), 0, gray.shape[0]-1)
    quality = .35 + .65 * np.minimum(1., gradient[y, x] / 24)
    return quality, dict(analysisRaster=[gray.shape[1], gray.shape[0]], meanGradient=float(np.mean(gradient)), maximumGradient=float(np.max(gradient)))


def bilinear_rgb(image, pixels):
    x, y = np.floor(pixels[:, 0]).astype(np.int64), np.floor(pixels[:, 1]).astype(np.int64)
    dx, dy = pixels[:, 0]-x, pixels[:, 1]-y
    require(np.all(x >= 0) and np.all(y >= 0) and np.all(x+1 < image.shape[1]) and np.all(y+1 < image.shape[0]), 'Sampling outside calibrated raster')
    value = image[y, x].astype(np.float64) * ((1-dx)*(1-dy))[:, None] + image[y, x+1].astype(np.float64) * (dx*(1-dy))[:, None]
    value += image[y+1, x].astype(np.float64) * ((1-dx)*dy)[:, None] + image[y+1, x+1].astype(np.float64) * (dx*dy)[:, None]
    return value[:, ::-1]  # OpenCV BGR -> encoded sRGB RGB; no WB/exposure invention.


def initialize_state(count):
    return dict(frame=np.full(count, -1, np.int32), score=np.zeros(count), rgb=np.full((count, 3), 128, np.uint8),
                rgbSample=np.full((count, 3), 128., np.float32), uv=np.full((count, 2), np.nan), residual=np.full(count, np.nan),
                depthCandidates=np.zeros(count, np.uint32), bvhTests=np.zeros(count, np.uint32), bvhRejected=np.zeros(count, np.uint32))


def consider_frame(index, frame, points, normals, normal_valid, image, depth, confidence, visibility, state):
    require(image.shape[:2] == (frame['imageHeight'], frame['imageWidth']), 'Image dimensions differ; no silent raster scaling')
    pixels, z, inside, center, k = project(frame, points)
    offset = center - points
    distance = np.linalg.norm(offset, axis=1)
    cosine = np.einsum('ij,ij->i', normals, offset) / np.maximum(distance, 1e-12)
    facing = (cosine > .05) | ~normal_valid
    support, residual, measured = depth_support(frame, pixels, z, depth, confidence)
    eligible = inside & facing & support
    state['depthCandidates'] += eligible.astype(np.uint32)
    quality, detail = detail_quality(image, pixels)
    angle = np.where(normal_valid, np.maximum(0., cosine)**2, 1.)
    score = (k[0, 0]*k[1, 1] / np.maximum(z*z, 1e-12)) * angle * quality / (1+residual)
    indices = np.flatnonzero(eligible & (score > state['score']))
    state['bvhTests'][indices] += 1
    blocked = visibility.occluded(center, points[indices])
    state['bvhRejected'][indices[blocked]] += 1
    accepted = indices[~blocked]
    samples = bilinear_rgb(image, pixels[accepted])
    state['frame'][accepted] = index
    state['score'][accepted] = score[accepted]
    state['uv'][accepted] = pixels[accepted]
    state['residual'][accepted] = residual[accepted]
    state['rgbSample'][accepted] = samples
    state['rgb'][accepted] = np.floor(samples + .5).clip(0, 255).astype(np.uint8)
    return dict(frameIndex=index, frameID=frame['id'], source=frame['source'], raster=[frame['imageWidth'], frame['imageHeight']],
                insideFrustum=int(np.count_nonzero(inside)), frontFacing=int(np.count_nonzero(inside & facing)),
                depthConsistentCandidates=int(np.count_nonzero(eligible)), potentiallyBetterBVHTests=len(indices),
                occludedByOriginalMesh=int(np.count_nonzero(blocked)), improvedAssignments=len(accepted), detail=detail)


def write_seed(path, lines, rows, rgb):
    result, row_index = [], 0
    for line in lines:
        if not line.strip() or line.lstrip().startswith('#'):
            result.append(line)
        else:
            fields = rows[row_index]
            result.append(' '.join(fields[:4] + [str(int(v)) for v in rgb[row_index]] + fields[7:]))
            row_index += 1
    require(row_index == len(rows), 'Point write count differs')
    path.write_text('\n'.join(result) + '\n')
    actual = [line.split() for line in path.read_text().splitlines() if line.strip() and not line.lstrip().startswith('#')]
    require(len(actual) == len(rows), 'Output lost points')
    require(all(x[:4] == y[:4] and x[7:] == y[7:] for x, y in zip(rows, actual)), 'A non-color source field changed')


def process(dataset, mesh_path, output, library):
    started = time.monotonic()
    manifest_path = dataset / 'dataset.json'
    manifest = json.loads(manifest_path.read_text())
    require(manifest['units'] == 'meters' and manifest['matrixLayout'] == 'columnMajor' and 'looks -Z' in manifest['cameraConvention'], 'Unknown calibration/depth convention')
    frames = manifest['frames']  # Stable original order, tie keeps first actual observation.
    require(frames, 'Empty dataset')
    source_points = dataset / 'points3D.txt'
    lines, rows, ids, points = read_points(source_points)
    mesh = json.loads(mesh_path.read_text())
    vertices = np.asarray(mesh['vertices'], np.float64)
    triangles = np.asarray(mesh['triangles'], np.uint32).reshape((-1, 3))
    normals, normal_valid, unique_vertices = normals_for_points(vertices, triangles, points)
    inputs = {str(p): p for p in [manifest_path, source_points, mesh_path]}
    for name in ('images.txt', 'cameras.txt'):
        if (dataset/name).is_file(): inputs[str(dataset/name)] = dataset/name
    for frame in frames:
        for key in ('rgbFile', 'depthFile', 'confidenceFile'):
            if frame.get(key):
                p = local(dataset, frame[key]); inputs[str(p)] = p
    before = {name: sha(p) for name, p in inputs.items()}
    write_json(output/'input-sha256-before.json', before)
    visibility = Visibility(library, vertices, triangles)
    state, statistics = initialize_state(len(points)), []
    try:
        for index, frame in enumerate(frames):
            if not frame.get('depthFile') or not frame.get('confidenceFile'):
                statistics.append(dict(frameIndex=index, frameID=frame['id'], skippedReason='No same-frame depth plus high-confidence evidence; not borrowed from another observation'))
                continue
            dw, dh = frame['depthWidth'], frame['depthHeight']
            require(dw >= 3 and dh >= 3, 'Depth too small for the conservative visibility footprint')
            depth = np.fromfile(local(dataset, frame['depthFile']), dtype='<f4')
            confidence = np.fromfile(local(dataset, frame['confidenceFile']), dtype=np.uint8)
            require(len(depth) == dw*dh and len(confidence) == dw*dh and np.all(confidence <= 2), 'Invalid depth/confidence byte count or level')
            depth, confidence = depth.reshape((dh, dw)), confidence.reshape((dh, dw))
            image = cv2.imread(str(local(dataset, frame['rgbFile'])), cv2.IMREAD_COLOR | cv2.IMREAD_IGNORE_ORIENTATION)
            require(image is not None, 'Cannot decode source RGB')
            statistics.append(consider_frame(index, frame, points, normals, normal_valid, image, depth, confidence, visibility, state))
            if index % 25 == 0 or index+1 == len(frames):
                print('FRAME', index+1, '/', len(frames), 'ASSIGNED', int(np.count_nonzero(state['frame'] >= 0)), flush=True)
    finally:
        visibility.close()
    write_seed(output/'points3D.txt', lines, rows, state['rgb'])
    observed = state['frame'] >= 0
    require(np.isfinite(state['score']).all() and np.isfinite(state['uv'][observed]).all() and np.isfinite(state['rgbSample']).all(), 'Invalid assigned color evidence')
    np.savez_compressed(output/'assignments.npz', pointIDs=ids, sourcePointCoordinates=points, normal=normals, normalValid=normal_valid, **state)
    with (output/'assignments.csv').open('w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['pointID','status','frameIndex','frameID','rgbFile','pixelX','pixelY','R','G','B','selectionScore','normalizedDepthResidual','depthCandidateCount','bvhTestCount','bvhRejectedCount'])
        for i, pid in enumerate(ids):
            index = int(state['frame'][i]); frame = frames[index] if index >= 0 else None
            writer.writerow([int(pid), 'photographic' if frame else 'unobserved-neutral', index, frame['id'] if frame else '', frame['rgbFile'] if frame else '',
                             *(state['uv'][i] if frame else ['', '']), *state['rgb'][i], state['score'][i], state['residual'][i] if frame else '',
                             state['depthCandidates'][i], state['bvhTests'][i], state['bvhRejected'][i]])
    after = {name: sha(p) for name, p in inputs.items()}
    write_json(output/'input-sha256-after.json', after)
    require(before == after, 'Source input changed during preparation')
    final_frames, counts = np.unique(state['frame'][observed], return_counts=True)
    report = dict(schemaVersion=1, status='prepared-not-trained', sourceDataset=str(dataset), sourceMesh=str(mesh_path), sourcePointsSHA256=before[str(source_points)],
                  seedPointsSHA256=sha(output/'points3D.txt'), pointCount=len(points), meshVertexCount=len(vertices), uniqueMeshVertexCount=unique_vertices,
                  photographicPointCount=int(np.count_nonzero(observed)), unobservedNeutralPointCount=int(np.count_nonzero(~observed)),
                  pointsWithUnknownAggregateNormal=int(np.count_nonzero(~normal_valid)), photosConsidered=len(frames), frames=statistics,
                  finalAssignmentCounts=[dict(frameIndex=int(i), frameID=frames[i]['id'], pointCount=int(n)) for i,n in zip(final_frames,counts)],
                  sourceHashFileCount=len(before), sourceSHA256Unchanged=True, nonColorPointTokensExactlyUnchanged=True,
                  elapsedSeconds=time.monotonic()-started, peakRSSMiB=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss/1048576,
                  configuration=dict(nativeRGBPixels=True, geometricPositionsCountIDsAndOrderUnchanged=True, noFrameQuota=True, noGPU=True,
                                     depth='Same-frame Float32 LE optical meters; all 3x3 samples finite and confidence2; residual<=max(.03m,.025*depth); neighborhood range<=same tolerance',
                                     visibility='Two-sided original-mesh BVH on every potentially better depth-supported candidate; endpoint exclusion max(.1mm,.001*rayLength)',
                                     selection='fx*fy/z^2 * positiveCosine^2 * photographicDetail / (1+normalizedDepthResidual); unknown aggregate normal uses angle factor1; exact ties retain earlier manifest observation',
                                     photographicDetail='1024px auxiliary gradient analysis only; factor .35+.65*min(1,gradient/24); flat photographs remain candidates',
                                     color='Bilinear native encoded sRGB from one winning actual photograph; quantize nearest to points3D RGB8; no multi-view blending, exposure/WB correction or synthetic pixels'),
                  limitations=['Preparation is not a quality result; no training or baseline comparison was executed.',
                               'LiDAR/ARKit pose uncertainty, unseen surfaces, specular/view-dependent appearance and exposure differences remain.',
                               'Coarse depth and original-mesh accuracy limit visibility; BVH endpoint exclusion cannot resolve sub-tolerance surfaces.',
                               'Area-weighted vertex normals can be ambiguous at hard edges; all original points remain and unknown normals are recorded.',
                               'Per-point candidate counts precede BVH; BVH tests only candidates that could beat the current score, not every possible visible observation.',
                               'Output only points3D.txt plus provenance; a future training arm must use a separate dataset/workspace and identical schedules/seeds to the gray baseline.'],
                  runtime=dict(numpy=np.__version__, opencv=cv2.__version__, openCL=bool(cv2.ocl.useOpenCL())), scriptSHA256=sha(Path(__file__)),
                  semanticSourceSHA256={str(p.relative_to(REPO)):sha(p) for p in [REPO/'Forma/Features/RGBDRecording.swift', REPO/'Forma/Core/RGBDDataset.swift', REPO/'Forma/Core/LiDARTextureBaker.swift']})
    write_json(output/'seed-manifest.json', report)
    (output/Path(__file__).name).write_bytes(Path(__file__).read_bytes())
    print('PREPARED', output/'seed-manifest.json', flush=True)
    return report


def fixture_frame(width=64, height=48):
    k = np.array([[32.,0,31.5],[0,32.,23.5],[0,0,1.]])
    return dict(id='fixture-camera', source='synthetic-fixture', imageWidth=width, imageHeight=height,
                cameraToWorld=np.eye(4).flatten(order='F').tolist(), intrinsics=k.flatten(order='F').tolist())


def self_test(library, output):
    frame = fixture_frame()
    # Two nearly coincident surfaces pass the coarse depth tolerance; BVH must
    # still reject the rear surface, even though triangle winding is arbitrary.
    front = np.array([[-.5,-.4,-2],[.5,-.4,-2],[0,.4,-2]], np.float64)
    points = np.concatenate((front,front+np.array([0,0,-.01])))
    triangles = np.array([[0,1,2],[3,4,5]], np.uint32)
    normals, valid, _ = normals_for_points(points, triangles, points)
    visibility = Visibility(library, points, triangles)
    state = initialize_state(6)
    image = np.empty((48,64,3),np.uint8); image[:]=[20,40,200]
    depth, confidence = np.full((12,16),2,np.float32),np.full((12,16),2,np.uint8)
    stat = consider_frame(0,frame,points,normals,valid,image,depth,confidence,visibility,state)
    visibility.close()
    require(np.all(state['frame'][:3] == 0) and np.all(state['frame'][3:] == -1), 'Rear close surface acquired foreground color')
    require(np.all(state['rgb'][:3] == [200,40,20]) and np.all(state['rgb'][3:] == 128) and stat['occludedByOriginalMesh'] == 3, 'Occlusion/color-order fixture failed')
    # A thin foreground strip absent from coarse depth must still occlude the
    # center of a background plane; reverse its winding to prove two-sidedness.
    vertices = np.array([[-.8,-.8,-4],[.8,-.8,-4],[.8,.8,-4],[-.8,.8,-4],[0,0,-4],[-.01,-.2,-2],[.01,-.2,-2],[.01,.2,-2],[-.01,.2,-2]],np.float64)
    faces=np.array([[0,1,4],[1,2,4],[2,3,4],[3,0,4],[5,7,6],[5,8,7]],np.uint32)
    visibility=Visibility(library,vertices,faces)
    require(visibility.occluded([0,0,0],vertices[[4]])[0], 'Thin sub-depth-raster occluder leaked background color')
    require(not visibility.occluded([0,0,0],vertices[[0]])[0], 'Clear background point falsely occluded')
    visibility.close()
    # A high-confidence depth edge is not a flat surface observation.
    depth=np.full((12,16),4,np.float32);depth[:,:8]=2
    pixels=np.array([[20.,24.],[30.,24.],[40.,24.]])
    accepted,_,_=depth_support(frame,pixels,np.array([2.,2.,4.]),depth,confidence)
    require(accepted.tolist()==[True,False,True], 'Depth-discontinuity footprint did not reject edge')
    confidence[6,5]=1
    accepted,_,_=depth_support(frame,pixels[:1],np.array([2.]),depth,confidence)
    require(not accepted[0], 'Low-confidence neighbor accepted')
    # Unequal resolutions with correspondingly scaled K preserve native rays.
    pixels,z,inside,_,_=project(frame,front)
    larger=dict(frame);larger['imageWidth']=128;larger['imageHeight']=96
    k=np.asarray(frame['intrinsics']).reshape((3,3),order='F');k[:2,:]*=2;larger['intrinsics']=k.flatten(order='F').tolist()
    larger_pixels,_,_,_,_=project(larger,front)
    require(np.max(np.abs(larger_pixels-2*pixels))<1e-10, 'K/native raster projection changed ray')
    # Write path changes only RGB tokens, preserving all IDs/positions/track data.
    source=output/'fixture-original-points3D.txt';source.write_text('# original\n7 0.000000 -0 -2.000 128 128 128 0.0 1 42\n')
    lines,rows,ids,pts=read_points(source);before=sha(source)
    write_seed(output/'fixture-colored-points3D.txt',lines,rows,np.array([[12,34,56]],np.uint8))
    require(sha(source)==before,'Fixture source changed')
    require(not cv2.ocl.useOpenCL(),'OpenCL enabled unexpectedly')
    result=dict(status='passed',fixtures=['close foreground/background surfaces inside depth tolerance','thin two-sided occluder absent from coarse depth','depth discontinuity and confidence neighborhood','ARKit native rays with unequal calibrated raster','RGB channel order and source point-token preservation'],sourceSHA256Unchanged=True)
    write_json(output/'fixture-tests.json',result)
    print('PASS',result['fixtures'])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset',type=Path,default=SCAN/'dataset')
    parser.add_argument('--mesh',type=Path,default=SCAN/'malla-original.json')
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args()
    output=args.output.resolve();require(not output.exists(),'Output must be a new isolated directory')
    require(not output.is_relative_to(args.dataset.resolve()),'Never write inside the source dataset')
    output.mkdir(parents=True)
    library=build_visibility(output)
    if args.self_test: self_test(library,output)
    else: process(args.dataset.resolve(),args.mesh.resolve(),output,library)


if __name__=='__main__':
    main()
