#!/usr/bin/env python3
"""CPU-only, read-only sparse pose/calibration audit of the recorded Forma room."""
from pathlib import Path
import os
os.environ['OPENCV_OPENCL_RUNTIME'] = 'disabled'
os.environ['OPENBLAS_NUM_THREADS'] = '2'
os.environ['OMP_NUM_THREADS'] = '2'
import argparse
import hashlib
import json
import math
import platform
import sys
import time
import cv2
import numpy as np
cv2.ocl.setUseOpenCL(False)
cv2.setNumThreads(2)
cv2.setRNGSeed(20261015)

REPO = Path(__file__).resolve().parent.parent
SCAN = Path.home() / 'Library/Application Support/FormaDesktop/Incoming/8CA53ED6-74E0-4AAB-9B13-6E562562081F'
FLIP = np.diag([1., -1., -1., 1.])
FIXED_PAIRS = [(0, 1, 'first-frame-to-next-observation'), (0, 5, 'first-frame-to-early-HiRes'),
               (1, 2, 'early-adjacent'), (282, 283, 'middle-adjacent-before'),
               (283, 284, 'middle-adjacent-after'), (278, 288, 'middle-wider-baseline'),
               (564, 565, 'last-stream-to-last-HiRes'), (560, 564, 'late-stream-span'),
               (555, 565, 'late-wider-baseline')]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + '\n')


def matmul(a, b):
    # Small-coordinate explicit contraction avoids inheriting floating-status
    # warnings from this NumPy/Accelerate build; every input/output stays checked.
    a, b = np.asarray(a, np.float64), np.asarray(b, np.float64)
    require(np.isfinite(a).all() and np.isfinite(b).all(), 'Nonfinite matrix input.')
    if a.ndim == 2 and b.ndim == 2:
        value = np.einsum('ik,kj->ij', a, b, optimize=False)
    elif a.ndim == 2 and b.ndim == 1:
        value = np.einsum('ij,j->i', a, b, optimize=False)
    else:
        raise ValueError('Unexpected matrix rank in CPU diagnostic.')
    require(np.isfinite(value).all(), 'Nonfinite explicit matrix result.')
    return value


def matrix(values, size):
    return np.asarray(values, np.float64).reshape((size, size), order='F')


def camera(frame):
    return matrix(frame['intrinsics'], 3), matmul(FLIP, np.linalg.inv(matrix(frame['cameraToWorld'], 4)))


def skew(t):
    x, y, z = t
    return np.array([[0., -z, y], [z, 0., -x], [-y, x, 0.]])


def relative(a, b):
    ka, ea = camera(a); kb, eb = camera(b)
    transform = matmul(eb, np.linalg.inv(ea))
    r, t = transform[:3, :3], transform[:3, 3]
    essential = matmul(skew(t), r)
    fundamental = matmul(matmul(np.linalg.inv(kb).T, essential), np.linalg.inv(ka))
    return ka, kb, r, t, fundamental


def homogeneous(points):
    return np.column_stack((points, np.ones(len(points))))


def sampson(f, a, b):
    xa, xb = homogeneous(a), homogeneous(b)
    la, lb = matmul(xa, f.T), matmul(xb, f)
    numerator = np.abs(np.einsum('ij,ij->i', xb, la))
    denominator = np.sqrt(la[:, 0] ** 2 + la[:, 1] ** 2 + lb[:, 0] ** 2 + lb[:, 1] ** 2)
    return numerator / np.maximum(denominator, 1e-30)


def symmetric_line(f, a, b):
    xa, xb = homogeneous(a), homogeneous(b)
    la, lb = matmul(xa, f.T), matmul(xb, f)
    numerator = np.abs(np.einsum('ij,ij->i', xb, la))
    da = numerator / np.maximum(np.linalg.norm(la[:, :2], axis=1), 1e-30)
    db = numerator / np.maximum(np.linalg.norm(lb[:, :2], axis=1), 1e-30)
    return np.sqrt((da ** 2 + db ** 2) / 2)


def distribution(values):
    values = np.asarray(values, np.float64)
    require(np.isfinite(values).all(), 'A diagnostic produced nonfinite distances.')
    if len(values) == 0:
        return dict(count=0)
    return dict(count=len(values), median=float(np.median(values)), mean=float(np.mean(values)),
                p90=float(np.percentile(values, 90)), p95=float(np.percentile(values, 95)), maximum=float(np.max(values)),
                fractionAtMost1=float(np.mean(values <= 1)), fractionAtMost2=float(np.mean(values <= 2)), fractionAtMost4=float(np.mean(values <= 4)))


def coverage(points, frame):
    if len(points) < 3:
        return dict(points=len(points), hullFraction=0., occupiedGridCells=0)
    area = cv2.contourArea(cv2.convexHull(np.float32(points)))
    bins = np.floor(points / [frame['imageWidth'], frame['imageHeight']] * 4).astype(int)
    cells = set(tuple(value) for value in np.clip(bins, 0, 3))
    return dict(points=len(points), hullFraction=float(area / (frame['imageWidth'] * frame['imageHeight'])), occupiedGridCells=len(cells), totalGridCells=16)


def quaternion_rotation(q):
    q = np.asarray(q, np.float64); q /= np.linalg.norm(q)
    w, x, y, z = q
    return np.array([[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                     [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                     [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]])


def calibration_audit(dataset, frames):
    cameras = {}
    for line in (dataset / 'cameras.txt').read_text().splitlines():
        if not line or line.startswith('#'): continue
        fields = line.split(); require(fields[1] == 'PINHOLE', 'This audit expects the actual exported PINHOLE model.')
        cameras[int(fields[0])] = (int(fields[2]), int(fields[3]), np.asarray(fields[4:8], float))
    images = {}
    lines = iter((dataset / 'images.txt').read_text().splitlines())
    for line in lines:
        if not line or line.startswith('#'): continue
        fields = line.split(maxsplit=9); require(len(fields) == 10, 'Unexpected image pose row.')
        images[fields[9]] = (np.asarray(fields[1:5], float), np.asarray(fields[5:8], float), int(fields[8]))
        next(lines, None)
    errors = []
    for frame in frames:
        k, e = camera(frame)
        q, t, camera_id = images[Path(frame['rgbFile']).name]
        width, height, packed_k = cameras[camera_id]
        require((width, height) == (frame['imageWidth'], frame['imageHeight']), 'COLMAP dimensions differ from manifest.')
        rotation = matrix(frame['cameraToWorld'], 4)[:3, :3]
        errors.append(dict(frameID=frame['id'], rotationMaxAbs=float(np.max(np.abs(quaternion_rotation(q) - e[:3, :3]))),
            translationMaxAbsMeters=float(np.max(np.abs(t - e[:3, 3]))),
            intrinsicsMaxAbsPixels=float(np.max(np.abs(packed_k - [k[0, 0], k[1, 1], k[0, 2], k[1, 2]]))),
            rotationOrthonormalMaxAbs=float(np.max(np.abs(matmul(rotation.T, rotation) - np.eye(3)))),
            offDiagonalIntrinsicsMaxAbs=float(max(abs(k[0, 1]), abs(k[1, 0]), abs(k[2, 0]), abs(k[2, 1])))))
    return dict(frameCount=len(frames), colmapImageCount=len(images), pinholeCameraCount=len(cameras),
        maxRotationMaxAbs=max(x['rotationMaxAbs'] for x in errors),
        maxTranslationMaxAbsMeters=max(x['translationMaxAbsMeters'] for x in errors),
        maxIntrinsicsMaxAbsPixels=max(x['intrinsicsMaxAbsPixels'] for x in errors),
        maxRotationOrthonormalError=max(x['rotationOrthonormalMaxAbs'] for x in errors),
        maxOffDiagonalIntrinsics=max(x['offDiagonalIntrinsicsMaxAbs'] for x in errors), frames=errors,
        observation='COLMAP observations are empty; exported measured poses stay fixed during Gaussian training. No bundle adjustment is present in this path.')


def select_pairs(frames, mesh):
    vertices = np.asarray(json.loads(mesh.read_text())['vertices'], np.float64)
    # Deterministic auxiliary frustum-overlap samples, never modification of scan geometry.
    step = max(1, math.ceil(len(vertices) / 10000))
    sample = vertices[::step]
    masks = []
    for frame in frames:
        k, e = camera(frame)
        points = matmul(sample, e[:3, :3].T) + e[:3, 3]
        z = points[:, 2]; pixels = matmul(points, k.T)
        with np.errstate(divide='ignore', invalid='ignore'):
            uv = pixels[:, :2] / z[:, None]
        masks.append((z > .1) & (uv[:, 0] >= 0) & (uv[:, 0] < frame['imageWidth']) & (uv[:, 1] >= 0) & (uv[:, 1] < frame['imageHeight']))
    pairs = [dict(a=a, b=b, reason=reason) for a, b, reason in FIXED_PAIRS]
    used = {tuple(sorted((x['a'], x['b']))) for x in pairs}
    for anchor in (0, 283, 565):
        candidates = []
        ca = matrix(frames[anchor]['cameraToWorld'], 4)[:3, 3]
        for index, frame in enumerate(frames):
            if abs(frame['timestamp'] - frames[anchor]['timestamp']) < 20 or tuple(sorted((anchor, index))) in used: continue
            cb = matrix(frame['cameraToWorld'], 4)[:3, 3]
            baseline = np.linalg.norm(cb - ca)
            if baseline < .05: continue
            shared = np.count_nonzero(masks[anchor] & masks[index])
            denom = math.sqrt(max(1, np.count_nonzero(masks[anchor])) * max(1, np.count_nonzero(masks[index])))
            score = shared / denom
            candidates.append((score, -baseline, index, shared))
        require(bool(candidates), 'No temporally distant pose-overlap candidate.')
        score, negative_baseline, chosen, shared = max(candidates)
        pairs.append(dict(a=anchor, b=chosen, reason='pose-predicted-temporal-revisit', selectionScore=float(score),
            sharedAuxiliaryMeshSamples=int(shared), selectionBaselineMeters=float(-negative_baseline)))
        used.add(tuple(sorted((anchor, chosen))))
    return pairs, dict(fullMeshVertexCount=len(vertices), sampledVertexCount=len(sample), deterministicVertexStride=step,
        minimumRevisitTimeSeparationSeconds=20, minimumRevisitBaselineMeters=.05, usesOcclusionTest=False,
        limitation='Shared projected mesh samples predict possible overlap only; feature matching checks the actual observations independently.')


def features(path):
    image = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE | cv2.IMREAD_IGNORE_ORIENTATION)
    require(image is not None, 'Could not decode source image: ' + str(path))
    sift = cv2.SIFT_create(nfeatures=0, nOctaveLayers=3, contrastThreshold=.04, edgeThreshold=10, sigma=1.6)
    keys, descriptors = sift.detectAndCompute(image, None)
    return np.asarray([key.pt for key in keys], np.float64), descriptors, image.shape


def mutual_matches(a, b):
    pa, da, _ = a; pb, db, _ = b
    if da is None or db is None or min(len(da), len(db)) < 2:
        return np.empty((0, 2)), np.empty((0, 2))
    matcher = cv2.BFMatcher(cv2.NORM_L2)
    def passing(left, right):
        return {x.queryIdx: x.trainIdx for pair in matcher.knnMatch(left, right, k=2) if len(pair) == 2 for x, y in [pair] if x.distance < .75 * y.distance}
    ab, ba = passing(da, db), passing(db, da)
    indices = [(i, j) for i, j in sorted(ab.items()) if ba.get(j) == i]
    return np.asarray([pa[i] for i, _ in indices]), np.asarray([pb[j] for _, j in indices])


def depth_reprojection(dataset, fa, fb, a, b, r, t, valid):
    if not fa.get('depthFile'):
        return dict(available=False, reason='No depth from this recorded frame; none borrowed from a different frame.')
    dw, dh = fa['depthWidth'], fa['depthHeight']
    depth = np.fromfile(dataset / fa['depthFile'], dtype='<f4').reshape((dh, dw))
    confidence = None
    if fa.get('confidenceFile'):
        confidence = np.fromfile(dataset / fa['confidenceFile'], dtype=np.uint8).reshape((dh, dw))
    ka, _ = camera(fa); kb, _ = camera(fb)
    selected = np.flatnonzero(valid)
    errors, used = [], []
    rejected = dict(outsideDepth=0, lowConfidence=0, depthDiscontinuity=0, invalidDepth=0, behindSecondCamera=0)
    for index in selected:
        u, v = a[index]
        x = int(math.floor((u + .5) * dw / fa['imageWidth']))
        y = int(math.floor((v + .5) * dh / fa['imageHeight']))
        if not (1 <= x < dw - 1 and 1 <= y < dh - 1): rejected['outsideDepth'] += 1; continue
        if confidence is not None and confidence[y, x] != 2: rejected['lowConfidence'] += 1; continue
        patch = depth[y-1:y+2, x-1:x+2]
        if not np.isfinite(patch).all() or np.min(patch) <= 0: rejected['invalidDepth'] += 1; continue
        z = float(depth[y, x])
        if float(np.max(patch) - np.min(patch)) > max(.05, .03 * z): rejected['depthDiscontinuity'] += 1; continue
        point = matmul(np.linalg.inv(ka), [u, v, 1.]) * z
        projected = matmul(r, point) + t
        if projected[2] <= 0: rejected['behindSecondCamera'] += 1; continue
        pixel = matmul(kb, projected); pixel = pixel[:2] / pixel[2]
        errors.append(np.linalg.norm(pixel - b[index])); used.append(index)
    return dict(available=True, sourceFrameID=fa['id'], depthRaster=[dw, dh], confidenceRequired=2 if confidence is not None else None,
        measuredMatches=len(errors), reprojectionPixels=distribution(errors), rejected=rejected,
        limitation='This joint residual mixes LiDAR depth uncertainty/registration, pose, intrinsics, occlusion and match error; not independent pose ground truth.')


def pair_evaluation(dataset, frames, pair, cache, output):
    ia, ib = pair['a'], pair['b']; fa, fb = frames[ia], frames[ib]
    a, b = mutual_matches(cache[ia], cache[ib])
    ka, kb, r, t, f_ar = relative(fa, fb)
    result = dict(pair, frameA=fa['id'], frameB=fb['id'], timeSeparationSeconds=float(abs(fa['timestamp'] - fb['timestamp'])),
        baselineMeters=float(np.linalg.norm(t)), featureCountA=len(cache[ia][0]), featureCountB=len(cache[ib][0]), mutualRatioMatches=len(a),
        rasterA=[fa['imageWidth'], fa['imageHeight']], rasterB=[fb['imageWidth'], fb['imageHeight']],
        arkitRelativeRotation=r.tolist(), arkitRelativeTranslation=t.tolist(), arkitFundamental=f_ar.tolist())
    if len(a) < 20:
        result.update(status='insufficient-matches', limitation='Too few mutual ratio matches for the predeclared train/test geometric diagnostic; no pose conclusion.')
        return result
    ar_error = sampson(f_ar, a, b)
    result['arkitAllMutualSampsonPixels'] = distribution(ar_error)
    result['arkitAllMutualSymmetricLinePixels'] = distribution(symmetric_line(f_ar, a, b))
    permutation = np.random.default_rng(20261015 + ia * 1000 + ib).permutation(len(a))
    test = permutation[::5]; train = np.setdiff1d(permutation, test)
    f_fit, mask = cv2.findFundamentalMat(a[train], b[train], cv2.USAC_MAGSAC, 1.5, .999, 10000)
    if f_fit is None or f_fit.shape != (3, 3):
        result.update(status='fundamental-estimation-failed'); return result
    fit_error = sampson(f_fit, a, b)
    fit_consistent = fit_error <= 1.5
    test_consistent = np.zeros(len(a), bool); test_consistent[test] = fit_consistent[test]
    result.update(status='measured', trainMatchCount=len(train), heldOutMatchCount=len(test),
        robustFundamental=f_fit.tolist(), fundamentalRansacTrainInliers=int(np.count_nonzero(mask)),
        robustFundamentalAllMutualSampsonPixels=distribution(fit_error), robustFundamentalHeldOutSampsonPixels=distribution(fit_error[test]),
        robustFundamentalHeldOutInlierFraction=float(np.mean(fit_consistent[test])),
        heldOutFundamentalConsistentCount=int(np.count_nonzero(test_consistent)),
        arkitHeldOutFundamentalConsistentSampsonPixels=distribution(ar_error[test_consistent]),
        robustHeldOutFundamentalConsistentSampsonPixels=distribution(fit_error[test_consistent]),
        arkitAllFundamentalConsistentSampsonPixels=distribution(ar_error[fit_consistent]),
        coverageA=coverage(a[fit_consistent], fa), coverageB=coverage(b[fit_consistent], fb))
    na = cv2.undistortPoints(a.reshape(-1, 1, 2), ka, None).reshape(-1, 2)
    nb = cv2.undistortPoints(b.reshape(-1, 1, 2), kb, None).reshape(-1, 2)
    focal = float(np.mean([ka[0, 0], ka[1, 1], kb[0, 0], kb[1, 1]]))
    essential, essential_mask = cv2.findEssentialMat(na[train], nb[train], np.eye(3), cv2.RANSAC, .999, 1.5 / focal, maxIters=10000)
    if essential is not None and essential.shape == (3, 3):
        recovered, re, te, cheirality = cv2.recoverPose(essential, na[train], nb[train], np.eye(3), mask=essential_mask.copy())
        fe = matmul(matmul(np.linalg.inv(kb).T, essential), np.linalg.inv(ka))
        ee = sampson(fe, a, b)
        rotation_error = math.degrees(math.acos(float(np.clip((np.trace(matmul(re, r.T)) - 1) / 2, -1, 1))))
        direction = float(np.clip(np.dot(te.ravel(), t) / np.linalg.norm(t), -1, 1))
        signed = math.degrees(math.acos(direction))
        rays_a = homogeneous(na); rays_a /= np.linalg.norm(rays_a, axis=1)[:, None]
        rays_b = matmul(homogeneous(nb), re); rays_b /= np.linalg.norm(rays_b, axis=1)[:, None]
        parallax = np.degrees(np.arccos(np.clip(np.einsum('ij,ij->i', rays_a, rays_b), -1, 1)))
        result['estimatedCalibratedPose'] = dict(rotationErrorFromARKitDegrees=rotation_error, translationDirectionSignedDegrees=signed,
            translationAxisDegrees=min(signed, 180-signed), translationScaleObservable=False, cheiralityInliers=int(recovered),
            essentialRansacTrainInliers=int(np.count_nonzero(essential_mask)), normalizedThreshold=1.5/focal,
            heldOutSampsonPixels=distribution(ee[test]), heldOutInlierFraction=float(np.mean(ee[test] <= 1.5)),
            medianParallaxOnFundamentalInliersDegrees=float(np.median(parallax[fit_consistent])) if np.any(fit_consistent) else None,
            rotation=re.tolist(), translationUnit=te.ravel().tolist(),
            limitation='R,t are uncertain for small baseline, planar scenes or weak cheirality; sign/direction alone cannot validate metric translation.')
    h, hmask = cv2.findHomography(a[train], b[train], cv2.USAC_MAGSAC, 2., maxIters=10000, confidence=.999)
    if h is not None:
        projected = matmul(homogeneous(a), h.T); projected = projected[:, :2] / projected[:, 2:]
        he = np.linalg.norm(projected-b, axis=1)
        result['homographyDegeneracyDiagnostic'] = dict(heldOutReprojectionPixels=distribution(he[test]),
            fractionOfHeldOutFundamentalInliersExplainedWithin2px=float(np.mean(he[test_consistent] <= 2)) if np.any(test_consistent) else None,
            limitation='High agreement can indicate a dominant plane or near-pure rotation; it makes essential-matrix translation less informative.')
    result['depthReprojection'] = depth_reprojection(dataset, fa, fb, a, b, r, t, test_consistent)
    np.savez_compressed(output / f'pair-{ia:03d}-{ib:03d}-matches.npz', pointsA=a, pointsB=b, trainIndices=train, heldOutIndices=test,
                        arkitSampsonPixels=ar_error, robustSampsonPixels=fit_error, robustConsistent=fit_consistent)
    return result


def self_test():
    rng = np.random.default_rng(42)
    ka = np.array([[2600., 0, 1920], [0, 2600, 1080], [0, 0, 1]])
    kb = np.array([[2860., 0, 2112], [0, 2860, 1188], [0, 0, 1]])
    r, _ = cv2.Rodrigues(np.array([.015, -.03, .01])); t = np.array([.2, .01, .02])
    points = np.column_stack((rng.uniform(-1, 1, 100), rng.uniform(-.5, .5, 100), rng.uniform(2, 5, 100)))
    project = lambda x, k: (matmul(x, k.T))[:, :2] / x[:, 2:]
    a, b = project(points, ka), project(matmul(points, r.T) + t, kb)
    f = matmul(matmul(matmul(np.linalg.inv(kb).T, skew(t)), r), np.linalg.inv(ka))
    require(np.max(sampson(f, a, b)) < 1e-8, 'Synthetic epipolar convention failed.')
    camera_a = np.eye(4); camera_b = np.eye(4); camera_b[:3, :3] = r; camera_b[:3, 3] = t
    frame_a = dict(intrinsics=ka.flatten(order='F').tolist(), cameraToWorld=FLIP.flatten(order='F').tolist())
    frame_b = dict(intrinsics=kb.flatten(order='F').tolist(), cameraToWorld=(matmul(np.linalg.inv(camera_b), FLIP)).flatten(order='F').tolist())
    _, _, _, _, derived = relative(frame_a, frame_b)
    require(np.max(sampson(derived, a, b)) < 1e-8, 'ARKit-to-CV relative-pose conversion failed.')
    wrong_r, _ = cv2.Rodrigues(np.array([.02, 0., 0.]))
    wrong = matmul(matmul(matmul(matmul(np.linalg.inv(kb).T, skew(t)), wrong_r), r), np.linalg.inv(ka))
    require(np.median(sampson(wrong, a, b)) > 1., 'Synthetic perturbation sensitivity failed.')
    require(not cv2.ocl.useOpenCL(), 'OpenCL must remain disabled.')
    print('PASS: synthetic calibrated pixels, ARKit/CV pose conversion, perturbation sensitivity; CPU only.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dataset', type=Path, default=SCAN / 'dataset')
    parser.add_argument('--mesh', type=Path, default=SCAN / 'malla-original.json')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    require(args.output is not None, 'A new isolated --output directory is required.')
    output, dataset, mesh = args.output.resolve(), args.dataset.resolve(), args.mesh.resolve()
    require(not output.exists(), 'Output must be new; no evidence or source is overwritten.')
    frames = sorted(json.loads((dataset / 'dataset.json').read_text())['frames'], key=lambda frame: frame['timestamp'])
    require(len(frames) == 566, 'This fixed-room study expects all 566 metadata records.')
    output.mkdir(parents=True)
    start = time.monotonic()
    audit = calibration_audit(dataset, frames); write_json(output / 'calibration-export-audit.json', audit)
    pairs, selection = select_pairs(frames, mesh)
    write_json(output / 'pair-selection-before-features.json', dict(pairs=pairs, selection=selection))
    indices = sorted(set(index for pair in pairs for index in (pair['a'], pair['b'])))
    inputs = {str(path): path for path in [mesh, dataset/'dataset.json', dataset/'cameras.txt', dataset/'images.txt', dataset/'points3D.txt']}
    for index in indices:
        for key in ('rgbFile', 'depthFile', 'confidenceFile'):
            if frames[index].get(key):
                path = (dataset / frames[index][key]).resolve(); require(path.is_relative_to(dataset), 'Input leaves its source dataset.'); inputs[str(path)] = path
    before = {name: digest(path) for name, path in inputs.items()}; write_json(output / 'input-sha256-before.json', before)
    cache, observations = {}, []
    for index in indices:
        frame = frames[index]; path = dataset / frame['rgbFile']
        cache[index] = features(path)
        require(cache[index][2] == (frame['imageHeight'], frame['imageWidth']), 'Decoded raster differs; no scaling correction applied silently.')
        observations.append(dict(index=index, frameID=frame['id'], file=str(path), width=frame['imageWidth'], height=frame['imageHeight'], source=frame['source'],
            imageSHA256=before[str(path)], siftFeatureCount=len(cache[index][0]), timestamp=frame['timestamp']))
        print('FEATURES',index,len(cache[index][0]),flush=True)
    write_json(output / 'observations.json', observations)
    results = []
    for pair in pairs:
        result = pair_evaluation(dataset, frames, pair, cache, output); results.append(result)
        write_json(output / 'pairs.json', results)
        print('PAIR',pair['a'],pair['b'],result['status'],result['mutualRatioMatches'],flush=True)
    after = {name: digest(path) for name, path in inputs.items()}; write_json(output / 'input-sha256-after.json', after)
    require(before == after, 'A selected source changed during this audit.')
    config = dict(featureRaster='native full resolution; no orientation transform', detector='SIFT all detected features; nfeatures=0',
        contrastThreshold=.04, edgeThreshold=10, nOctaveLayers=3, sigma=1.6, ratioThreshold=.75, matching='two-way ratio plus mutual nearest identity',
        fundamentalEstimator='USAC_MAGSAC', fundamentalThresholdNativePixels=1.5, ransacConfidence=.999, maxRansacIterations=10000,
        essentialEstimator='RANSAC on independently normalized coordinates, each frame uses its own K', essentialThresholdPixels=1.5,
        withinPairHeldOutCorrespondenceFraction=.2, correspondenceSplitSeedBase=20261015, noCameraOrIntrinsicOptimizationExecuted=True,
        openCL=False, cvThreads=2, pairCount=len(pairs), sourceImagesUnmodified=True)
    report = dict(status='completed', elapsedSeconds=time.monotonic()-start, dataset=str(dataset), mesh=str(mesh), totalMetadataFrames=len(frames),
        observedImageCount=len(indices), selectedSourceFileCount=len(before), sourceSHA256Unchanged=True, calibration=audit,
        pairSelection=selection, observations=observations, pairs=results, configuration=config,
        runtime=dict(python=sys.version, numpy=np.__version__, opencv=cv2.__version__, platform=platform.platform()),
        sources=['https://docs.opencv.org/4.12.0/d9/d0c/group__calib3d.html','https://docs.opencv.org/4.12.0/da/de9/tutorial_py_epipolar_geometry.html'],
        limitations=['12 selected pairs are a diagnostic sample, not a product quota or scan-wide accuracy certificate.',
            'The held-out set is correspondences inside the same pair, not held-out Gaussian training views.',
            'Epipolar consistency cannot recover metric translation scale or prove the cause of Gaussian blur.',
            'Planarity, low parallax, repeated patterns, lens distortion, rolling shutter, moving objects and feature error can affect pose fits.',
            'The dataset has no synchronized ISO/WB metadata; no missing calibration values are invented.'],
        scriptSHA256=digest(Path(__file__)))
    write_json(output/'report.json', report)
    (output/'evaluate_capture_pose_alignment.py').write_text(Path(__file__).read_text())
    print('COMPLETED',output/'report.json',flush=True)


if __name__ == '__main__':
    main()
