#!/usr/bin/env python3
"""CPU-only RGB-D TSDF experiment. Never writes into the capture or app library."""
import os
for _name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ[_name] = "2"
import argparse
import hashlib
import json
import math
from pathlib import Path
import time
import numpy as np
import open3d as o3d
from PIL import Image, ImageDraw

CV_FROM_ARKIT = np.diag([1., -1., -1., 1.])

def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()

def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False))

def calibration(frame):
    w, h = frame["depthWidth"], frame["depthHeight"]
    k = np.asarray(frame["intrinsics"], np.float64).reshape((3, 3), order="F").copy()
    k[0] *= w / frame["imageWidth"]
    k[1] *= h / frame["imageHeight"]
    assert abs(k[0, 1]) < 1e-9 and abs(k[1, 0]) < 1e-9
    t = np.asarray(frame["cameraToWorld"], np.float64).reshape((4, 4), order="F")
    e = CV_FROM_ARKIT @ np.linalg.inv(t)
    return w, h, k, e

def rays(frame):
    w, h, k, e = calibration(frame)
    v, u = np.mgrid[:h, :w]
    d = np.stack(((u-k[0, 2])/k[0, 0], (v-k[1, 2])/k[1, 1], np.ones_like(u)), axis=-1)
    c = np.linalg.inv(e)
    world_d = d @ c[:3, :3].T
    origin = np.broadcast_to(c[:3, 3], world_d.shape)
    return np.ascontiguousarray(np.concatenate((origin, world_d), axis=-1), np.float32)

def integrate(volume, frame, depth, depth_trunc):
    w, h, k, e = calibration(frame)
    rgbd = o3d.geometry.RGBDImage.create_from_color_and_depth(
        o3d.geometry.Image(np.zeros((h, w, 3), np.uint8)),
        o3d.geometry.Image(np.ascontiguousarray(depth, np.float32)),
        depth_scale=1., depth_trunc=depth_trunc, convert_rgb_to_intensity=False)
    intrinsic = o3d.camera.PinholeCameraIntrinsic(w, h, k[0, 0], k[1, 1], k[0, 2], k[1, 2])
    volume.integrate(rgbd, intrinsic, e)

def volume(voxel):
    return o3d.pipelines.integration.ScalableTSDFVolume(
        voxel_length=voxel, sdf_trunc=4*voxel,
        color_type=o3d.pipelines.integration.TSDFVolumeColorType.NoColor,
        depth_sampling_stride=1)

def synthetic(out):
    """Two disconnected planes, noncentral anisotropic K, rotated ARKit pose."""
    w, h = 96, 64
    k = np.array([[83., 0, 43.], [0, 91., 29.], [0, 0, 1.]])
    a, b = .31, -.19
    rz = np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1.]])
    ry = np.array([[math.cos(b), 0, math.sin(b)], [0, 1., 0], [-math.sin(b), 0, math.cos(b)]])
    base = np.eye(4); base[:3, :3] = rz @ ry; base[:3, 3] = [1.1, .4, -.3]
    e0 = CV_FROM_ARKIT @ np.linalg.inv(base)
    vol = volume(.01)
    frames = []
    for offset in (0., .05):
        t = base.copy(); t[:3, 3] += (base @ CV_FROM_ARKIT)[:3, :3] @ np.array([offset, -.4*offset, 0.])
        f = dict(depthWidth=w, depthHeight=h, imageWidth=w*2, imageHeight=h*2,
            intrinsics=(np.diag([2., 2., 1.]) @ k).flatten(order="F").tolist(), cameraToWorld=t.flatten(order="F").tolist())
        _, _, got_k, e = calibration(f)
        np.testing.assert_allclose(got_k, k, atol=1e-12)
        np.testing.assert_allclose(e @ t @ CV_FROM_ARKIT, np.eye(4), atol=1e-12)
        r = rays(f); o = r[..., :3] @ e0[:3, :3].T + e0[:3, 3]
        d = r[..., 3:] @ e0[:3, :3].T
        depth = np.zeros((h, w), np.float32)
        for z, xmin, xmax, ymin, ymax in ((1.2, -.44, -.15, -.22, .30), (2.2, .35, .90, -.30, .42)):
            optical = (z-o[..., 2]) / d[..., 2]
            point = o + optical[..., None] * d
            inside = (point[..., 0] >= xmin) & (point[..., 0] <= xmax) & (point[..., 1] >= ymin) & (point[..., 1] <= ymax) & (optical > 0)
            depth[inside] = optical[inside]
        frames.append((f, depth))
        integrate(vol, f, depth, 2.3)
    mesh = vol.extract_triangle_mesh()
    points = np.asarray(mesh.vertices) @ e0[:3, :3].T + e0[:3, 3]
    tri = np.asarray(mesh.triangles)
    assert len(points) and len(tri)
    plane_error = np.minimum(abs(points[:, 2]-1.2), abs(points[:, 2]-2.2))
    assert np.quantile(plane_error, .99) < .015, "Pose/K/optical-depth convention failed"
    assert not np.any((points[tri, 2].min(axis=1) < 1.4) & (points[tri, 2].max(axis=1) > 2.)), "TSDF fabricated a bridge between disjoint planes"
    clusters, counts, areas = mesh.cluster_connected_triangles()
    assert len(counts) == 2, "Two disconnected supported surfaces must remain disconnected"
    o3d.io.write_triangle_mesh(str(out/"synthetic-two-planes.ply"), mesh)
    report = dict(passed=True, cameraPoses=2, anisotropicNoncentralK=True, nativeToDepthScaling=2,
        arkitPoseNonIdentity=True, disconnectedSurfaceCount=len(counts), triangleCount=len(tri),
        planeDepthErrorP99Meters=float(np.quantile(plane_error, .99)), noBridgeFaces=True)
    write_json(out/"synthetic-report.json", report)
    print("Synthetic K/axes/disconnected-support PASS", report, flush=True)

def mesh_stats(mesh):
    v, t = np.asarray(mesh.vertices), np.asarray(mesh.triangles)
    edges = np.sort(np.concatenate((t[:, [0, 1]], t[:, [1, 2]], t[:, [2, 0]])), axis=1)
    unique, counts = np.unique(edges, axis=0, return_counts=True)
    boundary = unique[counts == 1]
    clusters, component_faces, component_areas = mesh.cluster_connected_triangles()
    return dict(vertices=len(v), triangles=len(t), boundsMin=v.min(axis=0).tolist(), boundsMax=v.max(axis=0).tolist(),
        areaSquareMeters=float(mesh.get_surface_area()), boundaryEdges=int((counts == 1).sum()),
        boundaryLengthMeters=float(np.linalg.norm(v[boundary[:, 0]]-v[boundary[:, 1]], axis=1).sum()),
        nonmanifoldEdges=int((counts > 2).sum()), connectedTriangleComponents=len(component_faces),
        largestComponentFaceFraction=float(max(component_faces)/len(t)),
        componentFacesDescending=sorted([int(c) for c in component_faces], reverse=True))

def scene(mesh):
    result = o3d.t.geometry.RaycastingScene(nthreads=2)
    result.add_triangles(o3d.t.geometry.TriangleMesh.from_legacy(mesh, device=o3d.core.Device("CPU:0")))
    return result

def geometry_image(hit, frame):
    depth = hit["t_hit"].numpy()
    normals = hit["primitive_normals"].numpy()
    r = rays(frame)[..., 3:]
    direction = r / np.linalg.norm(r, axis=-1, keepdims=True)
    # Two-sided diagnostic lighting changes no winding/faces. Record front/back
    # statistics separately; this is not the product renderer or a culling fix.
    light = .18+.82*np.abs((normals*direction).sum(axis=-1))
    rgb = np.zeros((*depth.shape, 3), np.uint8); rgb[:] = [17, 23, 31]
    color = np.clip(light[..., None]*np.array([210, 217, 225]), 0, 255).astype(np.uint8)
    valid = np.isfinite(depth); rgb[valid] = color[valid]
    return Image.fromarray(rgb).resize((768, 432), Image.Resampling.NEAREST)

def compare(dataset, frames, original, fused, confidence_min, out, voxel):
    scenes = [scene(original), scene(fused)]
    totals = [dict(valid=0, hits=0, within2cm=0, within5cm=0, backFacingHits=0, errors=[]) for _ in scenes]
    visual = {0, len(frames)//2, len(frames)-1}
    for i, f in enumerate(frames):
        depth = np.fromfile(dataset/f["depthFile"], "<f4").reshape(f["depthHeight"], f["depthWidth"])
        conf = np.fromfile(dataset/f["confidenceFile"], np.uint8).reshape(depth.shape)
        valid = np.isfinite(depth) & (depth > 0) & (conf >= confidence_min)
        ray = rays(f); panels = []
        for s, total in zip(scenes, totals):
            hit = s.cast_rays(o3d.core.Tensor(ray, dtype=o3d.core.Dtype.Float32, device=o3d.core.Device("CPU:0")), nthreads=2)
            d = hit["t_hit"].numpy(); keep = valid & np.isfinite(d)
            err = np.abs(d[keep]-depth[keep]).astype(np.float32)
            total["valid"] += int(valid.sum()); total["hits"] += int(keep.sum())
            total["within2cm"] += int((err <= .02).sum()); total["within5cm"] += int((err <= .05).sum())
            total["errors"].append(err)
            normals = hit["primitive_normals"].numpy()
            total["backFacingHits"] += int((keep & ((normals*ray[..., 3:]).sum(axis=-1) >= 0)).sum())
            if i in visual: panels.append(geometry_image(hit, f))
        if i in visual:
            photo = Image.open(dataset/f["rgbFile"]).convert("RGB").resize((768, 432), Image.Resampling.LANCZOS)
            img = Image.new("RGB", (2304, 472), (17, 23, 31)); draw = ImageDraw.Draw(img)
            for n, (panel, label) in enumerate(zip([photo]+panels, ["RGB original", "Malla original | diagnostico doble cara", f"TSDF {voxel*100:g} cm | diagnostico doble cara"])):
                img.paste(panel, (768*n, 40)); draw.text((768*n+12, 12), f"Vista {i}: {label}", fill="white")
            img.save(out/f"comparison-view-{i:03}.png")
        if (i+1) % 100 == 0: print("CPU raycast views", i+1, "/", len(frames), flush=True)
    reports = []
    for total in totals:
        errors = np.concatenate(total.pop("errors"))
        total.update(observedRayMeshMissFraction=1-total["hits"]/total["valid"],
            observedRaysWithin2cmFraction=total["within2cm"]/total["valid"],
            observedRaysWithin5cmFraction=total["within5cm"]/total["valid"],
            absoluteDepthErrorMeters=dict(mean=float(errors.mean()), median=float(np.median(errors)),
                p90=float(np.quantile(errors, .9)), p95=float(np.quantile(errors, .95)), p99=float(np.quantile(errors, .99))))
        reports.append(total)
    return dict(original=reports[0], fused=reports[1], queryFrames=len(frames),
        evaluationConfidenceMinimum=confidence_min,
        rayDirection="World rays unnormalized, camera Z=1; t_hit equals optical depth in meters", diagnosticRenderTwoSided=True)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--voxel", type=float, default=.01)
    parser.add_argument("--confidence-min", type=int, choices=(0, 1, 2), default=1)
    parser.add_argument("--evaluation-confidence-min", type=int, choices=(0, 1, 2), default=1)
    parser.add_argument("--self-test-only", action="store_true")
    args = parser.parse_args()
    assert args.voxel > 0 and math.isfinite(args.voxel)
    args.out.mkdir(parents=True, exist_ok=False)
    started = time.monotonic(); synthetic(args.out)
    if args.self_test_only: return
    dataset = args.dataset.resolve(); manifest = dataset/"dataset.json"
    frames = json.loads(manifest.read_text())["frames"]
    assert all(f.get("depthFile") and f.get("confidenceFile") for f in frames), "Do not silently skip observations"
    original_path = dataset.parent/"malla-original.json"
    hashes = {str(p): sha(p) for p in [manifest, original_path] + [dataset/f[k] for f in frames for k in ("depthFile", "confidenceFile")]}
    conf_hist = np.zeros(256, np.int64); max_depth = 0.; min_depth = math.inf
    valid_count = 0; masked_count = 0; point_min = np.full(3, np.inf); point_max = -point_min
    for f in frames:
        depth = np.fromfile(dataset/f["depthFile"], "<f4").reshape(f["depthHeight"], f["depthWidth"])
        conf = np.fromfile(dataset/f["confidenceFile"], np.uint8).reshape(depth.shape)
        conf_hist += np.bincount(conf.ravel(), minlength=256)
        valid = np.isfinite(depth) & (depth > 0) & (conf >= args.confidence_min)
        assert valid.any(), "An empty frame needs explicit reporting, not a quota/implicit skip"
        max_depth = max(max_depth, float(depth[valid].max())); min_depth = min(min_depth, float(depth[valid].min()))
        valid_count += int(valid.sum()); masked_count += int((~valid).sum())
        r = rays(f); points = r[..., :3][valid] + r[..., 3:][valid]*depth[valid, None]
        point_min = np.minimum(point_min, points.min(axis=0)); point_max = np.maximum(point_max, points.max(axis=0))
    depth_trunc = max_depth + max(args.voxel, np.finfo(np.float32).eps*max_depth*2)
    vol = volume(args.voxel); fusion_start = time.monotonic()
    for i, f in enumerate(frames):
        depth = np.fromfile(dataset/f["depthFile"], "<f4").reshape(f["depthHeight"], f["depthWidth"])
        conf = np.fromfile(dataset/f["confidenceFile"], np.uint8).reshape(depth.shape)
        depth[~(np.isfinite(depth) & (depth > 0) & (conf >= args.confidence_min))] = 0
        integrate(vol, f, depth, depth_trunc)
        if i == 11:
            estimate = (time.monotonic()-fusion_start)/12*len(frames)
            print("First 12-frame CPU estimate full fusion seconds:", round(estimate, 2), flush=True)
        if (i+1) % 50 == 0 or i+1 == len(frames): print("CPU TSDF frames", i+1, "/", len(frames), "seconds", round(time.monotonic()-fusion_start, 2), flush=True)
    fused = vol.extract_triangle_mesh(); fusion_seconds = time.monotonic()-fusion_start
    fused.compute_vertex_normals()
    assert len(fused.triangles) > 0
    o3d.io.write_triangle_mesh(str(args.out/"room-tsdf.ply"), fused, write_vertex_normals=True)
    o3d.io.write_triangle_mesh(str(args.out/"room-tsdf.obj"), fused, write_vertex_normals=True)
    with (args.out/"room-tsdf.json").open("w") as f:
        json.dump(dict(vertices=np.asarray(fused.vertices).tolist(), triangles=np.asarray(fused.triangles).ravel().tolist()), f, separators=(",", ":"), allow_nan=False)
    print("CANDIDATE", str((args.out/"room-tsdf.json").resolve()), "vertices", len(fused.vertices), "faces", len(fused.triangles), "fusion_seconds", fusion_seconds, flush=True)
    original_json = json.loads(original_path.read_text())
    original = o3d.geometry.TriangleMesh(o3d.utility.Vector3dVector(np.asarray(original_json["vertices"], np.float64)),
        o3d.utility.Vector3iVector(np.asarray(original_json["triangles"], np.int32).reshape(-1, 3)))
    original.compute_vertex_normals()
    report = dict(runtime=dict(open3d=o3d.__version__, numpy=np.__version__, device="CPU:0", threads=2),
        framesAvailable=len(frames), framesIntegrated=len(frames), frameQuota=None, voxelLengthMeters=args.voxel,
        signedDistanceTruncationMeters=4*args.voxel, depthTruncMeters=depth_trunc, measuredDepthMinMeters=min_depth, measuredDepthMaxMeters=max_depth,
        confidenceMinimum=args.confidence_min, confidenceHistogram={str(i): int(c) for i, c in enumerate(conf_hist) if c},
        confidencePolicy=f"Original confidence files retained unchanged; pixels with confidence >= {args.confidence_min} included at equal TSDF observation weight; other pixels masked, not frames",
        validOpticalDepthObservations=valid_count, maskedInvalidOrLowConfidencePixels=masked_count,
        observationWorldBounds=dict(min=point_min.tolist(), max=point_max.tolist()),
        fusionSeconds=fusion_seconds, original=mesh_stats(original), fused=mesh_stats(fused),
        postProcessing="No smoothing, hole filling, component removal, decimation, orientation flipping or geometry repair",
        cameraConversion="column-major ARKit cameraToWorld; E_CV=diag(1,-1,-1,1) @ inverse(T_AR); K raster-scaled directly",
        geometryCoordinates="Original ARKit world meters; unmodified camera poses",
        reference="https://www.open3d.org/docs/release/tutorial/pipelines/rgbd_integration.html")
    report["depthCoverage"] = compare(dataset, frames, original, fused, args.evaluation_confidence_min, args.out, args.voxel)
    for i in {0, len(frames)//2, len(frames)-1}:
        p = dataset/frames[i]["rgbFile"]; hashes[str(p)] = sha(p)
    after = {p: sha(Path(p)) for p in hashes}
    report["inputSHA256Unchanged"] = hashes == after
    assert hashes == after, "Input changed during experiment"
    report["inputFilesVerified"] = len(hashes)
    report["totalSeconds"] = time.monotonic()-started
    write_json(args.out/"input-sha256.json", hashes)
    write_json(args.out/"report.json", report)
    print(json.dumps({k:v for k,v in report.items() if k not in ("original", "fused", "depthCoverage")}, indent=2), flush=True)

if __name__ == "__main__":
    main()
