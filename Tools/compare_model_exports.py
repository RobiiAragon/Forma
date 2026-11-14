#!/usr/bin/env python3
"""Inspect two user-supplied model exports with Blender, without altering either.

Run with Blender's bundled Python; no packages or services are installed:
  /Applications/Blender.app/Contents/MacOS/Blender --background --python \
    Tools/compare_model_exports.py -- --forma /path/modelo.obj \
    --polycam /path/room.glb --output /path/private-report

Optional: --skip-render, --resolution 960 720, --samples 24,
--views top oblique interior, --yaw-degrees 90 --translation 1 0 0,
--forma-metadata captura.json, --overwrite.
Use --inspection-only to append eight readable, correctly framed albedo/solid
inspection renders to an existing report while preserving legacy renders.

All dimensions assume the exports' declared meters. Alignment allows gravity-axis
yaw and translation only, never scaling. Automatic alignment is a sampled shape
heuristic and is ALWAYS reported as unverified, never as ground-truth accuracy.
Native connectivity is not a physical-hole detector: anchor seams, texture seams,
intentional openings, cropping and duplicated vertices can all change its counts.
"""

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import sys
import time
from datetime import datetime, timezone

import bpy
import numpy as np
from mathutils import Matrix, Vector, kdtree


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--forma", required=True, type=Path)
    parser.add_argument("--polycam", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--forma-metadata", type=Path)
    parser.add_argument("--resolution", nargs=2, type=int, default=[1200, 900], metavar=("WIDTH", "HEIGHT"))
    parser.add_argument("--samples", type=int, default=24)
    parser.add_argument("--views", nargs="+", choices=["top", "oblique", "interior"], default=["top", "oblique", "interior"])
    parser.add_argument("--skip-render", action="store_true")
    parser.add_argument("--inspection-only", action="store_true",
                        help="Append corrected unlit/solid inspection passes to an existing report")
    parser.add_argument("--yaw-degrees", type=float, help="Explicit yaw for Polycam in Blender Z-up coordinates")
    parser.add_argument("--translation", nargs=3, type=float, metavar=("X", "Y", "Z"))
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    for path in [args.forma, args.polycam]:
        if not path.is_file():
            parser.error(f"Input file does not exist: {path}")
    if min(args.resolution) < 32 or args.samples < 1:
        parser.error("Resolution must be at least 32 pixels per axis; samples must be positive.")
    if (args.yaw_degrees is None) != (args.translation is None):
        parser.error("Manual alignment requires both --yaw-degrees and --translation.")
    if args.inspection_only and (args.skip_render or not (args.output / "comparison.json").is_file()):
        parser.error("--inspection-only requires an existing comparison.json and cannot use --skip-render.")
    if args.output.exists() and any(args.output.iterdir()) and not args.overwrite and not args.inspection_only:
        parser.error("Output is not empty. Select another folder or explicitly use --overwrite.")
    return args


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def source_obj_counts(path):
    """Count source OBJ indices before the importer discards unused vertices."""
    if path.suffix.lower() != ".obj":
        return None
    count, referenced = 0, set()
    with path.open() as handle:
        for line in handle:
            tokens = line.split()
            if not tokens:
                continue
            if tokens[0] == "v":
                count += 1
            elif tokens[0] == "f":
                for token in tokens[1:]:
                    index = int(token.partition("/")[0])
                    referenced.add(index - 1 if index > 0 else count + index)
    if any(index < 0 or index >= count for index in referenced):
        raise ValueError("Source OBJ has out-of-range face indices")
    return {"vertex_records": count, "face_referenced_vertices": len(referenced),
            "unreferenced_vertices": count - len(referenced),
            "note": "Source text counts before OBJ import; unused vertices do not contribute geometry or detail."}


def glb_images(path):
    """Encoded image sizes/hashes from the actual GLB chunks, not decoded GPU RAM."""
    if path.suffix.lower() != ".glb":
        return []
    with path.open("rb") as handle:
        data = handle.read()
    if len(data) < 20 or data[:4] != b"glTF":
        raise ValueError("Invalid GLB header")
    document = None
    binary = None
    offset = 12
    while offset + 8 <= len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        offset += 8
        chunk = data[offset:offset + length]
        if len(chunk) != length:
            raise ValueError("Truncated GLB chunk")
        if kind == 0x4E4F534A:
            document = json.loads(chunk)
        elif kind == 0x004E4942:
            binary = chunk
        offset += length
    if document is None:
        raise ValueError("Missing GLB JSON chunk")
    images = []
    for index, image in enumerate(document.get("images", [])):
        entry = {"index": index, "name": image.get("name"), "mime_type": image.get("mimeType")}
        if "bufferView" in image and binary is not None:
            view = document["bufferViews"][image["bufferView"]]
            start, length = view.get("byteOffset", 0), view["byteLength"]
            encoded = binary[start:start + length]
            entry.update(encoded_bytes=length, sha256=hashlib.sha256(encoded).hexdigest(), storage="embedded")
        elif "uri" in image:
            entry.update(storage="uri", uri=image["uri"])
        images.append(entry)
    return images


def import_model(label, path):
    before = set(bpy.data.objects)
    begin = time.perf_counter()
    extension = path.suffix.lower()
    if extension == ".obj":
        # Forma explicitly exports Y-up, -Z-forward, meter-valued coordinates.
        bpy.ops.wm.obj_import(filepath=str(path), global_scale=1.0, clamp_size=0.0,
                              forward_axis="NEGATIVE_Z", up_axis="Y",
                              use_split_objects=False, use_split_groups=False, validate_meshes=True)
    elif extension in [".glb", ".gltf"]:
        # glTF's standard Y-up, meter-valued coordinates are converted by Blender.
        bpy.ops.import_scene.gltf(filepath=str(path), import_pack_images=True)
    else:
        raise ValueError(f"Unsupported model extension: {extension}")
    objects = [obj for obj in bpy.data.objects if obj not in before and obj.type == "MESH"]
    if not objects:
        raise ValueError(f"No mesh objects imported from {path}")
    for obj in [obj for obj in bpy.data.objects if obj not in before and obj.type != "MESH"]:
        if obj.type in ["CAMERA", "LIGHT"]:
            bpy.data.objects.remove(obj, do_unlink=True)
    for obj in objects:
        obj.name = label + "_" + obj.name
    return {"label": label, "path": path, "objects": objects,
            "import_seconds_mac": time.perf_counter() - begin,
            "original_matrices": {obj.name: obj.matrix_world.copy() for obj in objects}}


def world_geometry(model):
    vertices, triangles = [], []
    object_reports = []
    base = 0
    for obj in model["objects"]:
        mesh = obj.data
        mesh.calc_loop_triangles()
        local = np.empty((len(mesh.vertices), 3), dtype=np.float64)
        mesh.vertices.foreach_get("co", local.ravel())
        transform = np.asarray(obj.matrix_world, dtype=np.float64)
        world = local @ transform[:3, :3].T + transform[:3, 3]
        faces = np.empty((len(mesh.loop_triangles), 3), dtype=np.int64)
        mesh.loop_triangles.foreach_get("vertices", faces.ravel())
        vertices.append(world)
        triangles.append(faces + base)
        base += len(world)
        object_reports.append({"name": obj.name, "vertices": len(mesh.vertices),
                               "polygons": len(mesh.polygons), "triangles": len(mesh.loop_triangles),
                               "uv_layers": len(mesh.uv_layers), "color_attributes": len(mesh.color_attributes),
                               "material_slots": len(mesh.materials),
                               "imported_world_matrix": transform.tolist()})
    world = np.concatenate(vertices)
    faces = np.concatenate(triangles)
    if not np.isfinite(world).all() or not len(faces):
        raise ValueError("The model has non-finite geometry or no triangles")
    model.update(vertices=world, triangles=faces, object_reports=object_reports)


def topology(vertices, triangles):
    begin = time.perf_counter()
    edge_pairs = np.concatenate((triangles[:, [0, 1]], triangles[:, [1, 2]], triangles[:, [2, 0]]))
    edge_pairs.sort(axis=1)
    edges, incidence = np.unique(edge_pairs, axis=0, return_counts=True)
    lengths = np.linalg.norm(vertices[edges[:, 1]] - vertices[edges[:, 0]], axis=1)
    boundary = incidence == 1
    parents = np.arange(len(vertices), dtype=np.int64)
    ranks = np.zeros(len(vertices), dtype=np.int8)

    def root(vertex):
        while parents[vertex] != vertex:
            parents[vertex] = parents[parents[vertex]]
            vertex = int(parents[vertex])
        return vertex

    for a, b in edges:
        left, right = root(int(a)), root(int(b))
        if left == right:
            continue
        if ranks[left] < ranks[right]:
            left, right = right, left
        parents[right] = left
        if ranks[left] == ranks[right]:
            ranks[left] += 1
    roots = np.fromiter((root(index) for index in range(len(vertices))), dtype=np.int64)
    component_sizes = np.sort(np.unique(roots, return_counts=True)[1])[::-1]
    boundary_degrees = np.bincount(edges[boundary].ravel(), minlength=len(vertices))
    used = np.bincount(triangles.ravel(), minlength=len(vertices)) > 0
    unique_coordinates = len(np.unique(vertices, axis=0))
    return {"definition": "raw index-connected components and triangle edge incidences; no welding, repairs or hole filling",
            "components_including_isolated_vertices": int(len(component_sizes)),
            "largest_component_vertices": int(component_sizes[0]),
            "largest_component_vertex_fraction": float(component_sizes[0] / len(vertices)),
            "ten_largest_component_vertex_counts": component_sizes[:10].tolist(),
            "isolated_vertices": int(np.count_nonzero(~used)),
            "unique_edges": int(len(edges)),
            "boundary_edges_incidence_one": int(np.count_nonzero(boundary)),
            "boundary_edge_total_length_m_proxy": float(lengths[boundary].sum()),
            "nonmanifold_edges_incidence_over_two": int(np.count_nonzero(incidence > 2)),
            "boundary_vertices_degree_two": int(np.count_nonzero(boundary_degrees == 2)),
            "boundary_vertices_branched_or_open": int(np.count_nonzero((boundary_degrees != 0) & (boundary_degrees != 2))),
            "exact_coincident_vertex_count": int(len(vertices) - unique_coordinates),
            "warning": "These are export-topology proxies, NOT physical hole counts or an accuracy score. Anchor/texture splits and duplicate vertices can create many raw components and boundary edges.",
            "analysis_seconds_mac": time.perf_counter() - begin}


def material_images(model):
    entries = {}
    materials = set()
    for obj in model["objects"]:
        for material in obj.data.materials:
            if material is None:
                continue
            materials.add(material.name)
            if not material.use_nodes:
                continue
            for node in material.node_tree.nodes:
                image = node.image if node.type == "TEX_IMAGE" else None
                if image is None:
                    continue
                key = image.as_pointer()
                if key not in entries:
                    packed = image.packed_file
                    raw = bytes(packed.data) if packed else None
                    entry = {"name": image.name, "native_width_px": int(image.size[0]),
                             "native_height_px": int(image.size[1]), "channels": image.channels,
                             "source": image.source, "colorspace": image.colorspace_settings.name,
                             "packed_encoded_bytes": len(raw) if raw is not None else None,
                             "encoded_sha256": hashlib.sha256(raw).hexdigest() if raw is not None else None}
                    if image.filepath and not packed:
                        external = Path(bpy.path.abspath(image.filepath))
                        entry["external_file"] = str(external)
                        if external.is_file():
                            entry.update(external_encoded_bytes=external.stat().st_size,
                                         encoded_sha256=sha256(external))
                    entries[key] = entry
    return {"material_count": len(materials), "material_names": sorted(materials),
            "photographic_image_count": len(entries), "images": list(entries.values()),
            "note": "Image dimensions are the actual embedded/external source rasters; no atlas or image is resized by this comparison."}


def summarize(model):
    vertices, triangles = model["vertices"], model["triangles"]
    cross = np.cross(vertices[triangles[:, 1]] - vertices[triangles[:, 0]],
                     vertices[triangles[:, 2]] - vertices[triangles[:, 0]])
    areas = np.linalg.norm(cross, axis=1) * 0.5
    lower, upper = vertices.min(axis=0), vertices.max(axis=0)
    model["areas"] = areas
    model["bounds"] = (lower, upper)
    return {"input_file": str(model["path"].resolve()), "input_bytes": model["path"].stat().st_size,
            "input_sha256": sha256(model["path"]), "mesh_objects": len(model["objects"]),
            "source_obj_counts": source_obj_counts(model["path"]),
            "vertex_count_raw": len(vertices), "triangle_count": len(triangles),
            "degenerate_triangle_count": int(np.count_nonzero(areas <= 1e-12)),
            "triangle_surface_area_m2_proxy": float(areas.sum()),
            "bounding_box_z_up_m": {"min": lower.tolist(), "max": upper.tolist(), "extent": (upper - lower).tolist()},
            "objects": model["object_reports"], "textures": material_images(model),
            "glb_encoded_images": glb_images(model["path"]), "topology": topology(vertices, triangles),
            "import_seconds_mac": model["import_seconds_mac"],
            "metric_warning": "Meters assume source export units. Bounds/area/topology describe this asset and its coverage, not room ground truth; more triangles do not establish more real detail."}


def surface_samples(model, count, seed):
    probabilities = model["areas"] / model["areas"].sum()
    rng = np.random.default_rng(seed)
    indices = rng.choice(len(model["triangles"]), count, p=probabilities)
    corners = model["vertices"][model["triangles"][indices]]
    u = np.sqrt(rng.random(count))
    v = rng.random(count)
    return corners[:, 0] * (1 - u[:, None]) + corners[:, 1] * (u * (1 - v))[:, None] + corners[:, 2] * (u * v)[:, None]


def tree(points):
    result = kdtree.KDTree(len(points))
    for index, point in enumerate(points):
        result.insert(point.tolist(), index)
    result.balance()
    return result


def nearest(points, target_tree):
    matched = np.empty_like(points)
    distances = np.empty(len(points))
    for index, point in enumerate(points):
        coordinate, _, distance = target_tree.find(point.tolist())
        matched[index] = coordinate
        distances[index] = distance
    return matched, distances


def yaw_matrix(angle):
    c, s = math.cos(angle), math.sin(angle)
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]], dtype=np.float64)


def align_models(reference, moving, args):
    begin = time.perf_counter()
    warning = ("Unverified rigid visualization alignment. No scale, pitch or roll fitting. "
               "Sampled nearest-neighbor distances are shape-overlap heuristics, not reconstruction error or physical accuracy.")
    if args.yaw_degrees is not None:
        angle = math.radians(args.yaw_degrees)
        translation = np.asarray(args.translation)
        candidates = []
        method = "explicit user/operator supplied yaw and translation"
    else:
        target = surface_samples(reference, 16000, 20261015)
        source = surface_samples(moving, 4000, 20261016)
        target_tree = tree(target)
        candidates = []
        for initial_degrees in range(0, 360, 15):
            angle = math.radians(initial_degrees)
            rotation = yaw_matrix(angle)
            translation = np.median(target, axis=0) - np.median(source @ rotation.T, axis=0)
            for _ in range(15):
                transformed = source @ rotation.T + translation
                matches, distances = nearest(transformed, target_tree)
                keep = distances <= np.quantile(distances, 0.70)
                left, right = source[keep], matches[keep]
                left_center, right_center = left.mean(axis=0), right.mean(axis=0)
                a, b = left - left_center, right - right_center
                angle = math.atan2(np.sum(a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0]),
                                   np.sum(a[:, 0] * b[:, 0] + a[:, 1] * b[:, 1]))
                rotation = yaw_matrix(angle)
                translation = right_center - rotation @ left_center
            _, distances = nearest(source @ rotation.T + translation, target_tree)
            trimmed = np.sort(distances)[:int(len(distances) * 0.7)]
            candidates.append({"initial_yaw_degrees": initial_degrees, "yaw_degrees": math.degrees(angle) % 360,
                               "translation_m": translation.tolist(),
                               "trimmed_one_direction_nn_proxy_m": float(trimmed.mean()),
                               "median_one_direction_nn_proxy_m": float(np.median(distances))})
        candidates.sort(key=lambda item: item["trimmed_one_direction_nn_proxy_m"])
        best = candidates[0]
        angle = math.radians(best["yaw_degrees"])
        translation = np.asarray(best["translation_m"])
        method = "deterministic area-sampled yaw+translation multi-start ICP; trimmed 70%; 24 yaw starts; no deformation"
    rotation = yaw_matrix(angle)
    transform = np.eye(4)
    transform[:3, :3] = rotation
    transform[:3, 3] = translation
    blender_transform = Matrix(transform.tolist())
    for obj in moving["objects"]:
        obj.matrix_world = blender_transform @ moving["original_matrices"][obj.name]
    moving["aligned_vertices"] = moving["vertices"] @ rotation.T + translation
    close_other_yaws = [item for item in candidates[1:] if abs((item["yaw_degrees"] - math.degrees(angle) + 180) % 360 - 180) > 15
                        and item["trimmed_one_direction_nn_proxy_m"] <= candidates[0]["trimmed_one_direction_nn_proxy_m"] * 1.05]
    return {"status": "not_verified", "method": method, "gravity_assumption": "both inputs' declared vertical axes become Blender +Z",
            "reference": reference["label"], "moving": moving["label"], "scale": 1.0,
            "yaw_degrees": math.degrees(angle) % 360, "translation_m": translation.tolist(),
            "matrix_z_up_row_major": transform.tolist(), "rotation_determinant": float(np.linalg.det(rotation)),
            "competing_yaw_within_five_percent_proxy": bool(close_other_yaws),
            "best_candidates": candidates[:5], "alignment_seconds_mac": time.perf_counter() - begin,
            "warning": warning}


def backface_culled(material):
    material.use_nodes = True
    material.use_backface_culling = True
    nodes = material.node_tree.nodes
    links = material.node_tree.links
    output = next((node for node in nodes if node.type == "OUTPUT_MATERIAL" and node.is_active_output), None)
    if output is None:
        output = nodes.new("ShaderNodeOutputMaterial")
    existing = next(iter(output.inputs["Surface"].links), None)
    if existing is None:
        return material
    shader = existing.from_socket
    transparent = nodes.new("ShaderNodeBsdfTransparent")
    geometry = nodes.new("ShaderNodeNewGeometry")
    mix = nodes.new("ShaderNodeMixShader")
    links.new(geometry.outputs["Backfacing"], mix.inputs[0])
    links.new(shader, mix.inputs[1])
    links.new(transparent.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], output.inputs["Surface"])
    return material


def rendering_setup(args):
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = args.samples
    scene.cycles.use_denoising = False
    scene.render.resolution_x, scene.render.resolution_y = args.resolution
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.render.film_transparent = False
    scene.render.threads_mode = "AUTO"
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"
    scene.view_settings.exposure = 0
    scene.view_settings.gamma = 1
    scene.world = bpy.data.worlds.new("ComparisonWorld")
    scene.world.use_nodes = True
    background = scene.world.node_tree.nodes.get("Background")
    background.inputs["Color"].default_value = (0.055, 0.06, 0.067, 1)
    background.inputs["Strength"].default_value = 0.65
    solid = bpy.data.materials.new("ComparisonNeutralGray")
    solid.use_nodes = True
    principled = solid.node_tree.nodes.get("Principled BSDF")
    principled.inputs["Base Color"].default_value = (0.55, 0.55, 0.55, 1)
    principled.inputs["Roughness"].default_value = 1
    principled.inputs["Metallic"].default_value = 0
    backface_culled(solid)
    return scene, solid


def camera_for_view(name, lower, upper, args):
    center = (lower + upper) * 0.5
    extent = upper - lower
    diagonal = float(np.linalg.norm(extent))
    data = bpy.data.cameras.new("ComparisonCamera_" + name)
    camera = bpy.data.objects.new("ComparisonCamera_" + name, data)
    bpy.context.scene.collection.objects.link(camera)
    if name == "interior":
        position = center.copy()
        position[2] = min(upper[2] - 0.2, lower[2] + 1.55)
        direction = np.array([0.7, 1.0, 0.0])
        target = position + direction
        data.type = "PERSP"
        data.lens = 18
        data.clip_start = 0.03
    else:
        direction = np.array([0.0, 0.0, 1.0]) if name == "top" else np.array([1.0, -1.3, 1.2])
        direction /= np.linalg.norm(direction)
        position = center + direction * diagonal * 1.8
        target = center
        data.type = "ORTHO"
        data.clip_start = 0.03
    camera.location = position.tolist()
    camera.rotation_euler = (Vector(target.tolist()) - camera.location).to_track_quat("-Z", "Y").to_euler()
    data.clip_end = max(100, diagonal * 10)
    if data.type == "ORTHO":
        inverse_rotation = camera.rotation_euler.to_matrix().transposed()
        corners = [Vector((x, y, z)) - camera.location for x in [lower[0], upper[0]]
                   for y in [lower[1], upper[1]] for z in [lower[2], upper[2]]]
        projected = np.asarray([inverse_rotation @ corner for corner in corners])
        visible_extent = projected.max(axis=0) - projected.min(axis=0)
        # ortho_scale is the landscape frame WIDTH, not height. Query the actual
        # frame so portrait/aspect/pixel-aspect changes also remain correct.
        data.ortho_scale = 1.0
        frame = np.asarray([tuple(corner) for corner in data.view_frame(scene=bpy.context.scene)])
        frame_extent = frame.max(axis=0) - frame.min(axis=0)
        data.ortho_scale = float(max(visible_extent[0] / frame_extent[0],
                                     visible_extent[1] / frame_extent[1]) * 1.12)
    return camera


def camera_frame_audit(camera, vertices):
    """Check every source vertex, not just camera-space bounding-box corners."""
    rotation = np.asarray(camera.rotation_euler.to_matrix(), dtype=np.float64)
    camera_space = (vertices - np.asarray(camera.location)) @ rotation
    frame = np.asarray([tuple(corner) for corner in camera.data.view_frame(scene=bpy.context.scene)])
    lower, upper = frame[:, :2].min(axis=0), frame[:, :2].max(axis=0)
    inside = np.all((camera_space[:, :2] >= lower - 1e-5) &
                    (camera_space[:, :2] <= upper + 1e-5), axis=1)
    return {"all_vertices_inside_orthographic_frame": bool(inside.all()),
            "outside_vertex_count": int((~inside).sum()),
            "camera_space_frame_min_xy_m": lower.tolist(),
            "camera_space_frame_max_xy_m": upper.tolist()}


def unlit_base_color(material, neutral):
    """Keep the imported base-color graph/images; bypass metallic/PBR lighting."""
    if material is None:
        return neutral
    result = material.copy()
    result.name = material.name + "_InspectionAlbedo"
    result.use_nodes = True
    nodes, links = result.node_tree.nodes, result.node_tree.links
    principled = next((node for node in nodes if node.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        raise ValueError("Albedo inspection requires a readable Principled base-color input")
    color = principled.inputs["Base Color"]
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Strength"].default_value = 1.0
    if color.is_linked:
        links.new(color.links[0].from_socket, emission.inputs["Color"])
    else:
        emission.inputs["Color"].default_value = color.default_value
    output = next((node for node in nodes if node.type == "OUTPUT_MATERIAL" and node.is_active_output), None)
    if output is None:
        output = nodes.new("ShaderNodeOutputMaterial")
    links.new(emission.outputs[0], output.inputs["Surface"])
    return backface_culled(result)


def render_inspection(models, args):
    """Readable source-albedo and common-shaded geometry; never a device benchmark."""
    # All light/material overrides are render-only. Imported geometry is untouched.
    scene, solid = rendering_setup(args)
    scene.cycles.samples = 64
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.16, 0.17, 0.19, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.8
    # A declared, common low emission floor keeps occluded interior geometry
    # legible; it is an inspection shader, never a physically lit appearance.
    solid_bsdf = solid.node_tree.nodes.get("Principled BSDF")
    solid_bsdf.inputs["Emission Color"].default_value = (0.55, 0.55, 0.55, 1)
    solid_bsdf.inputs["Emission Strength"].default_value = 0.25
    neutral = bpy.data.materials.new("InspectionNeutralUnlitGray")
    neutral.use_nodes = True
    nodes = neutral.node_tree.nodes
    nodes.clear()
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = (0.55, 0.55, 0.55, 1)
    emission.inputs["Strength"].default_value = 1
    output = nodes.new("ShaderNodeOutputMaterial")
    neutral.node_tree.links.new(emission.outputs[0], output.inputs["Surface"])
    backface_culled(neutral)
    all_vertices = np.concatenate([models[0]["vertices"], models[1]["aligned_vertices"]])
    lower, upper = all_vertices.min(axis=0), all_vertices.max(axis=0)
    diagonal = float(np.linalg.norm(upper - lower))
    originals, albedos = {}, {}
    for model in models:
        for obj in model["objects"]:
            indices = np.empty(len(obj.data.polygons), dtype=np.int32)
            obj.data.polygons.foreach_get("material_index", indices)
            materials = list(obj.data.materials)
            originals[obj.name] = (materials, indices)
            albedos[obj.name] = [unlit_base_color(material, neutral) for material in materials]
    light_data = bpy.data.lights.new("InspectionCameraFill", "AREA")
    light_data.energy = 5000
    light_data.shape = "DISK"
    light_data.size = diagonal * 0.8
    light = bpy.data.objects.new("InspectionCameraFill", light_data)
    scene.collection.objects.link(light)
    renders = []
    for view_name in ["top", "oblique"]:
        camera = camera_for_view(view_name, lower, upper, args)
        scene.camera = camera
        audit = camera_frame_audit(camera, all_vertices)
        if not audit["all_vertices_inside_orthographic_frame"]:
            raise ValueError("Corrected inspection camera unexpectedly crops a source model")
        # A broad camera-side fill reveals front-facing surfaces in both assets.
        light.location = camera.location
        light.rotation_euler = camera.rotation_euler
        for mode in ["albedo", "inspection"]:
            for active_model in models:
                for model in models:
                    for obj in model["objects"]:
                        obj.hide_render = model is not active_model
                        obj.data.materials.clear()
                        _, indices = originals[obj.name]
                        materials = albedos[obj.name]
                        if mode == "inspection" or not materials:
                            obj.data.materials.append(solid if mode == "inspection" else neutral)
                            obj.data.polygons.foreach_set("material_index", np.zeros(len(indices), dtype=np.int32))
                        else:
                            for material in materials:
                                obj.data.materials.append(material)
                            obj.data.polygons.foreach_set("material_index", indices)
                filename = f"{active_model['label'].lower()}_{view_name}_{mode}.png"
                scene.render.filepath = str(args.output / filename)
                begin = time.perf_counter()
                bpy.ops.render.render(write_still=True)
                renders.append({"file": filename, "model": active_model["label"], "view": view_name, "mode": mode,
                                "render_seconds_mac_cpu": time.perf_counter() - begin,
                                "photographic_source_present": active_model["summary"]["textures"]["photographic_image_count"] > 0,
                                "fallback": "neutral unlit gray; this source contains no photographs" if mode == "albedo" and not active_model["summary"]["textures"]["photographic_image_count"] else None,
                                "camera_location_z_up_m": list(camera.location),
                                "camera_rotation_euler_radians": list(camera.rotation_euler),
                                "camera_type": "ORTHO", "ortho_scale_m": camera.data.ortho_scale,
                                "framing_audit": audit})
    return {"created_at_utc": datetime.now(timezone.utc).isoformat(),
            "engine": "Cycles", "device": "CPU", "samples": 64, "denoising": False,
            "resolution_px": args.resolution, "view_transform": "Standard", "identical_setup_per_pair": True,
            "albedo": "Original imported base-color texture graph to emission strength 1; no metallic, roughness, shadows, exposure edits or invented photographs. Textureless sources use identical neutral gray emission.",
            "inspection": "Identical neutral matte gray material with common emission strength 0.25 for visibility in occluded interiors, world strength 0.8 and broad camera-side area light 5000W, size 0.8 times union diagonal; same shader and lights per pair. This is diagnostic shading, not physically realistic appearance.",
            "framing": "One shared camera per view, eight union bounding-box corners projected into camera axes and fitted using actual Blender view_frame aspect; all source vertices verified inside frame.",
            "backface_culling": "Identical Geometry.Backfacing transparent shader; no normal flipping or repair",
            "geometry_changes": "None: no welding, decimation, subdivision, filling, normal repair, scale fitting or source image resizing",
            "alignment_status": "not_verified",
            "limitations": ["Existing captures have unknown/different trajectories, framing, settings and processing budgets.",
                            "Rigid alignment remains unverified and has competing yaw solutions; these are source-asset inspections, not pixel correspondence or geometric error measurements.",
                            "Source albedo can contain baked capture lighting; these passes do not establish color accuracy without photographs/ground truth.",
                            "Mac CPU render times are not iPhone FPS or either app's capture/processing performance.",
                            "Triangle counts, exported area and raw topology do not establish true optical detail, completeness or dimensional accuracy."],
            "renders": renders}


def render_models(models, args):
    scene, solid = rendering_setup(args)
    all_vertices = np.concatenate([models[0]["vertices"], models[1]["aligned_vertices"]])
    lower, upper = all_vertices.min(axis=0), all_vertices.max(axis=0)
    center = (lower + upper) * 0.5
    diagonal = float(np.linalg.norm(upper - lower))
    for name, offset, energy, size in [("Key", [-0.5, -0.8, 1.2], 1800, 5), ("Fill", [0.8, 0.5, 0.8], 1100, 4)]:
        data = bpy.data.lights.new("Comparison" + name, "AREA")
        data.energy = energy
        data.shape = "DISK"
        data.size = size
        obj = bpy.data.objects.new("Comparison" + name, data)
        scene.collection.objects.link(obj)
        obj.location = (center + np.asarray(offset) * diagonal).tolist()
        obj.rotation_euler = (Vector(center.tolist()) - obj.location).to_track_quat("-Z", "Y").to_euler()
    originals = {}
    for model in models:
        for obj in model["objects"]:
            indices = np.empty(len(obj.data.polygons), dtype=np.int32)
            obj.data.polygons.foreach_get("material_index", indices)
            materials = [backface_culled(material.copy()) if material else solid for material in obj.data.materials]
            originals[obj.name] = (materials, indices)
    renders = []
    for view_name in args.views:
        camera = camera_for_view(view_name, lower, upper, args)
        scene.camera = camera
        for mode in ["solid", "original"]:
            for active_model in models:
                for model in models:
                    for obj in model["objects"]:
                        obj.hide_render = model is not active_model
                        obj.data.materials.clear()
                        materials, indices = originals[obj.name]
                        if mode == "solid" or not materials:
                            obj.data.materials.append(solid)
                            obj.data.polygons.foreach_set("material_index", np.zeros(len(indices), dtype=np.int32))
                        else:
                            for material in materials:
                                obj.data.materials.append(material)
                            obj.data.polygons.foreach_set("material_index", indices)
                filename = f"{active_model['label'].lower()}_{view_name}_{mode}.png"
                scene.render.filepath = str(args.output / filename)
                begin = time.perf_counter()
                bpy.ops.render.render(write_still=True)
                renders.append({"file": filename, "model": active_model["label"], "view": view_name, "mode": mode,
                                "photographic_source_present": active_model["summary"]["textures"]["photographic_image_count"] > 0,
                                "fallback": "neutral gray; no photograph invented" if mode == "original" and not active_model["summary"]["textures"]["photographic_image_count"] else None,
                                "render_seconds_mac_cpu": time.perf_counter() - begin,
                                "camera_location_z_up_m": list(camera.location),
                                "camera_rotation_euler_radians": list(camera.rotation_euler),
                                "camera_type": camera.data.type, "ortho_scale_m": camera.data.ortho_scale if camera.data.type == "ORTHO" else None,
                                "lens_mm": camera.data.lens if camera.data.type == "PERSP" else None})
    return {"engine": "Cycles", "device": "CPU", "samples": args.samples, "denoising": False,
            "resolution_px": args.resolution, "view_transform": "Standard", "identical_setup_per_pair": True,
            "backface_culling": "same Geometry.Backfacing transparent shader on both; authored normals retained",
            "geometry_changes": "none; no decimation, welding, subdivision, filling, smoothing or scale fitting",
            "original_material_mode": "copied original materials with backface culling; photographic rasters not resized; textureless models explicitly neutral gray",
            "interior_camera_warning": "Heuristic eye at union-center XY and 1.55m above minimum Z; may intersect furniture or fall outside differently cropped captures.",
            "renders": renders}


def save_report(report, output):
    temporary = output / "comparison.json.pending"
    temporary.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    temporary.replace(output / "comparison.json")


def main():
    args = arguments()
    args.forma, args.polycam, args.output = args.forma.resolve(), args.polycam.resolve(), args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    models = [import_model("Forma", args.forma), import_model("Polycam", args.polycam)]
    for model in models:
        world_geometry(model)
        model["summary"] = summarize(model)
    if args.inspection_only:
        report = json.loads((args.output / "comparison.json").read_text())
        # Existing renders are preserved byte-for-byte, but their old framing
        # must never be mistaken for these corrected inspection passes.
        for model in models:
            previous = report["models"][model["label"]]
            if previous["input_sha256"] != model["summary"]["input_sha256"]:
                raise ValueError("Inspection input differs from the existing report")
            previous["source_obj_counts"] = model["summary"]["source_obj_counts"]
        if "rendering" in report:
            report["rendering"].update(
                status="legacy diagnostic framing invalid",
                valid_for_quality_claims=False,
                warning="Legacy orthographic sizing confused width and height and can crop assets. Interior camera and dark PBR lighting are also unsuitable for quality claims. Preserved for traceability only; use rendering_inspection.")
        report["alignment"] = align_models(models[0], models[1], args)
        save_report(report, args.output)
        report["rendering_inspection"] = render_inspection(models, args)
        save_report(report, args.output)
        print("FORMA_INSPECTION_REPORT " + str(args.output / "comparison.json"), flush=True)
        return
    report = {"schema_version": 1, "created_at_utc": datetime.now(timezone.utc).isoformat(),
              "blender_version": bpy.app.version_string, "tool": str(Path(__file__).resolve()),
              "privacy": "Local processing only. Input photographs/model renders remain in the requested output folder.",
              "comparison_scope": "Two user-supplied existing captures of the same reported room; paths, trajectories, capture settings, elapsed Polycam capture time and processing budgets are not controlled or known.",
              "not_measured": ["ground-truth geometric accuracy", "certified dimensions", "iPhone FPS", "Polycam processing speed", "which app is superior", "real optical detail from triangle count"],
              "models": {model["label"]: model["summary"] for model in models}}
    if args.forma_metadata:
        report["models"]["Forma"]["capture_metadata"] = json.loads(args.forma_metadata.read_text())
    report["alignment"] = align_models(models[0], models[1], args)
    save_report(report, args.output)  # Preserve analysis even if a renderer fails.
    if not args.skip_render:
        report["rendering"] = render_models(models, args)
        save_report(report, args.output)
    print("FORMA_COMPARISON_REPORT " + str(args.output / "comparison.json"), flush=True)


if __name__ == "__main__":
    main()
