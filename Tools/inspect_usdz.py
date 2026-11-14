#!/usr/bin/env python3
"""Read-only USDZ inventory and native-texture inspection with bundled Blender.

Run only after the reconstruction and its final save have completed:
  /Applications/Blender.app/Contents/MacOS/Blender --background --python \
    Tools/inspect_usdz.py -- --input /absolute/modelo.usdz \
    --output /absolute/new-private-inspection

No downloads, app UI, reconstruction, source extraction, mesh repair, alignment,
scale fitting or texture resizing. The source archive and referenced assets must
be self-contained. Output is JSON and local diagnostic PNGs, never a new model.
Optional --skip-render and --topology (additional raw connectivity analysis).
Declared USD units do not certify the photographic model's physical scale.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import stat
import sys
import time
import zipfile

import bpy
import numpy as np
from pxr import Sdf, Usd, UsdGeom


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--resolution", type=int, nargs=2, default=[1200, 900])
    parser.add_argument("--samples", type=int, default=64)
    parser.add_argument("--inspection-light-watts", type=float, default=150.0,
                        help="Diagnostic camera fill, explicitly recorded; independent of unlit albedo")
    parser.add_argument("--skip-render", action="store_true")
    parser.add_argument("--topology", action="store_true")
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    args.input, args.output = args.input.resolve(), args.output.resolve()
    if not args.input.is_file() or args.input.suffix.lower() != ".usdz":
        parser.error("A completed USDZ file is required")
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("Output must be new or empty; existing reports are preserved")
    if min(args.resolution) < 32 or args.samples < 1 or args.inspection_light_watts < 0:
        parser.error("Positive render samples and resolution of at least 32 pixels are required")
    if args.output == args.input.parent:
        parser.error("Choose a separate output directory")
    return args


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def safe_name(name):
    return bool(name) and not name.startswith("/") and "\\" not in name and "\0" not in name and all(part not in ("", ".", "..") for part in name.rstrip("/").split("/"))


def archive_inventory(path):
    entries, names = [], set()
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            if not safe_name(info.filename) or info.filename in names:
                raise ValueError("Unsafe or duplicate USDZ member: " + repr(info.filename))
            names.add(info.filename)
            if stat.S_ISLNK(info.external_attr >> 16):
                raise ValueError("USDZ symbolic links are not accepted")
            if info.is_dir():
                continue
            checksum, count = hashlib.sha256(), 0
            with archive.open(info) as handle:
                for block in iter(lambda: handle.read(1024 * 1024), b""):
                    checksum.update(block)
                    count += len(block)
            if count != info.file_size:
                raise ValueError("Truncated USDZ member")
            entries.append({"name": info.filename, "bytes": count, "encoded_bytes": info.compress_size,
                            "compression": info.compress_type, "sha256": checksum.hexdigest(),
                            "crc32": f"{info.CRC:08x}"})
    return {"members": entries, "file_count": len(entries), "all_member_crc_reads_succeeded": True,
            "uncompressed_bytes": sum(entry["bytes"] for entry in entries),
            "first_member": entries[0]["name"] if entries else None,
            "extracted_to_disk": False}


def stage_inventory(path):
    stage = Usd.Stage.Open(str(path))
    if not stage:
        raise ValueError("USD stage could not be opened")
    prefix = str(path)
    def contained(resolved):
        return not resolved or resolved == prefix or resolved.startswith(prefix + "[")
    layers = [str(layer.identifier) for layer in stage.GetUsedLayers()]
    outside = [layer for layer in layers if not layer.startswith("anon:") and not contained(layer)]
    if outside:
        raise ValueError("USDZ uses external layers: " + repr(outside))
    meshes, asset_paths, materials = [], [], []
    for prim in stage.Traverse():
        if prim.IsA(UsdGeom.Mesh):
            mesh = UsdGeom.Mesh(prim)
            points = mesh.GetPointsAttr().Get()
            counts = mesh.GetFaceVertexCountsAttr().Get()
            indices = mesh.GetFaceVertexIndicesAttr().Get()
            meshes.append({"path": str(prim.GetPath()), "source_points": len(points) if points is not None else 0,
                           "source_polygons": len(counts) if counts is not None else 0,
                           "source_face_corners": len(indices) if indices is not None else 0,
                           "subdivision_scheme": str(mesh.GetSubdivisionSchemeAttr().Get()),
                           "orientation": str(mesh.GetOrientationAttr().Get()),
                           "visibility": str(mesh.GetVisibilityAttr().Get())})
        if prim.GetTypeName() == "Material":
            materials.append(str(prim.GetPath()))
        for attribute in prim.GetAttributes():
            kind = attribute.GetTypeName()
            if kind not in (Sdf.ValueTypeNames.Asset, Sdf.ValueTypeNames.AssetArray):
                continue
            value = attribute.Get()
            values = [value] if kind == Sdf.ValueTypeNames.Asset else (value or [])
            for asset in values:
                if not asset or not asset.path:
                    continue
                resolved = str(asset.resolvedPath)
                if not resolved or not contained(resolved):
                    raise ValueError("Missing or external USD asset: " + str(asset.path))
                asset_paths.append({"attribute": str(attribute.GetPath()), "authored": str(asset.path), "resolved": resolved})
    result = {"up_axis": str(UsdGeom.GetStageUpAxis(stage)),
              "meters_per_unit": float(UsdGeom.GetStageMetersPerUnit(stage)),
              "up_axis_authored": stage.HasAuthoredMetadata("upAxis"),
              "meters_per_unit_authored": stage.HasAuthoredMetadata("metersPerUnit"),
              "used_layers": layers, "meshes": meshes, "material_paths": materials,
              "asset_dependencies": asset_paths,
              "scale_warning": "Declared USD units only; photographic reconstruction scale is not registered to LiDAR or an external reference."}
    return result


def helpers():
    path = Path(__file__).with_name("compare_model_exports.py")
    spec = importlib.util.spec_from_file_location("forma_export_inspection_helpers", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def import_asset(args):
    begin = time.perf_counter()
    bpy.ops.wm.read_factory_settings(use_empty=True)
    # Pack native bytes in memory. No source files or external texture folders
    # are overwritten. Disable authored subdivision to inspect the base mesh.
    settings = {"filepath": str(args.input), "scale": 1.0,
                "apply_unit_conversion_scale": True, "import_cameras": False,
                "import_lights": False, "import_meshes": True,
                "read_mesh_uvs": True, "read_mesh_colors": True,
                "import_materials": True, "import_usd_preview": True,
                "import_subdivision": False, "support_scene_instancing": False,
                "import_visible_only": True, "import_textures_mode": "IMPORT_PACK",
                "create_world_material": False, "validate_meshes": False}
    result = bpy.ops.wm.usd_import(**settings)
    if result != {"FINISHED"}:
        raise ValueError("USD import did not finish")
    objects = [obj for obj in bpy.context.scene.objects if obj.type == "MESH"]
    if not objects:
        raise ValueError("USDZ contains no imported visible mesh")
    return {"label": "USDZ", "path": args.input, "objects": objects,
            "import_seconds_mac": time.perf_counter() - begin}, settings


def mesh_summary(model, utils, detailed_topology):
    utils.world_geometry(model)
    vertices, triangles = model["vertices"], model["triangles"]
    lower, upper = vertices.min(axis=0), vertices.max(axis=0)
    result = {"visible_mesh_objects": len(model["objects"]), "imported_vertices": len(vertices),
              "imported_polygons": sum(len(obj.data.polygons) for obj in model["objects"]),
              "render_triangles": len(triangles), "objects": model["object_reports"],
              "bounds_in_declared_meter_coordinates_blender_z_up": {
                  "min": lower.tolist(), "max": upper.tolist(), "extent": (upper - lower).tolist()},
              "textures": utils.material_images(model),
              "topology": utils.topology(vertices, triangles) if detailed_topology else {
                  "computed": False, "reason": "Optional raw connectivity analysis requires --topology; inventory and renders do not require it."}}
    # All imported image nodes are listed: normal/roughness maps must not be
    # miscounted as separate photographic observations.
    result["textures"]["image_node_count"] = result["textures"].pop("photographic_image_count")
    result["textures"]["note"] = "Native imported image rasters; includes all texture-map roles, not a count of source capture photographs. No source image is resized."
    return result


def unlit_material(material, neutral, utils):
    """Bypass lighting while retaining the imported base-color AND opacity graphs."""
    if material is None:
        return neutral
    result = material.copy()
    result.name = material.name + "_USDZNativeAlbedo"
    result.use_nodes = True
    nodes, links = result.node_tree.nodes, result.node_tree.links
    principled = next((node for node in nodes if node.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        raise ValueError("No readable imported Principled base-color/alpha graph")
    emission = nodes.new("ShaderNodeEmission")
    color = principled.inputs["Base Color"]
    if color.is_linked:
        links.new(color.links[0].from_socket, emission.inputs["Color"])
    else:
        emission.inputs["Color"].default_value = color.default_value
    transparent = nodes.new("ShaderNodeBsdfTransparent")
    mix = nodes.new("ShaderNodeMixShader")
    links.new(transparent.outputs[0], mix.inputs[1])
    links.new(emission.outputs[0], mix.inputs[2])
    alpha = principled.inputs["Alpha"]
    if alpha.is_linked:
        links.new(alpha.links[0].from_socket, mix.inputs[0])
    else:
        mix.inputs[0].default_value = alpha.default_value
    output = next((node for node in nodes if node.type == "OUTPUT_MATERIAL" and node.is_active_output), None)
    if output is None:
        output = nodes.new("ShaderNodeOutputMaterial")
    links.new(mix.outputs[0], output.inputs["Surface"])
    return utils.backface_culled(result)


def render_asset(model, args, utils):
    scene, solid = utils.rendering_setup(args)
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.16, 0.17, 0.19, 1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.8
    shader = solid.node_tree.nodes.get("Principled BSDF")
    shader.inputs["Emission Color"].default_value = (0.55, 0.55, 0.55, 1)
    shader.inputs["Emission Strength"].default_value = 0.25
    neutral = bpy.data.materials.new("USDZInspectionNeutralUnlit")
    neutral.use_nodes = True
    nodes = neutral.node_tree.nodes
    nodes.clear()
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = (0.55, 0.55, 0.55, 1)
    output = nodes.new("ShaderNodeOutputMaterial")
    neutral.node_tree.links.new(emission.outputs[0], output.inputs["Surface"])
    utils.backface_culled(neutral)
    saved, unlit, unsupported = {}, {}, []
    for obj in model["objects"]:
        indices = np.empty(len(obj.data.polygons), dtype=np.int32)
        obj.data.polygons.foreach_get("material_index", indices)
        saved[obj.name] = (list(obj.data.materials), indices)
        try:
            unlit[obj.name] = [unlit_material(material, neutral, utils) for material in obj.data.materials]
        except ValueError as error:
            unsupported.append({"object": obj.name, "reason": str(error)})
    vertices = model["vertices"]
    lower, upper = vertices.min(axis=0), vertices.max(axis=0)
    diagonal = float(np.linalg.norm(upper - lower))
    light_data = bpy.data.lights.new("USDZInspectionCameraFill", "AREA")
    light_data.energy = args.inspection_light_watts
    light_data.shape = "DISK"
    light_data.size = diagonal * 0.8
    light = bpy.data.objects.new("USDZInspectionCameraFill", light_data)
    scene.collection.objects.link(light)
    renders = []
    modes = ["inspection"] if unsupported else ["albedo", "inspection"]
    for view in ["top", "oblique"]:
        camera = utils.camera_for_view(view, lower, upper, args)
        scene.camera = camera
        audit = utils.camera_frame_audit(camera, vertices)
        if not audit["all_vertices_inside_orthographic_frame"]:
            raise ValueError("USDZ inspection camera crops the asset")
        light.location, light.rotation_euler = camera.location, camera.rotation_euler
        for mode in modes:
            for obj in model["objects"]:
                materials, indices = saved[obj.name]
                obj.data.materials.clear()
                if mode == "inspection" or not materials:
                    obj.data.materials.append(solid if mode == "inspection" else neutral)
                    obj.data.polygons.foreach_set("material_index", np.zeros(len(indices), dtype=np.int32))
                else:
                    for material in unlit[obj.name]:
                        obj.data.materials.append(material)
                    obj.data.polygons.foreach_set("material_index", indices)
            filename = f"usdz_{view}_{mode}.png"
            scene.render.filepath = str(args.output / filename)
            begin = time.perf_counter()
            bpy.ops.render.render(write_still=True)
            renders.append({"file": filename, "view": view, "mode": mode,
                            "render_seconds_mac_cpu": time.perf_counter() - begin,
                            "camera_location_blender_z_up": list(camera.location),
                            "camera_rotation_euler_radians": list(camera.rotation_euler),
                            "ortho_scale_declared_meters": camera.data.ortho_scale, "framing_audit": audit})
    return {"engine": "Cycles", "device": "CPU", "samples": args.samples,
            "resolution_px": args.resolution, "denoising": False, "view_transform": "Standard",
            "backfaces": "Original face orientation retained; identical Geometry.Backfacing transparent shader in every pass",
            "albedo": "Imported base-color and opacity graphs retained with emission, original raster dimensions; no metallic/PBR lighting. Omitted when graph cannot be interpreted.",
            "neutral_inspection": "Opaque geometry with shared matte gray, emission floor 0.25, world 0.8 and broad camera-side fill; diagnostic visibility, not physical lighting.",
            "neutral_inspection_fill_watts": args.inspection_light_watts,
            "unsupported_albedo": unsupported, "renders": renders,
            "geometry_changes": "None; no subdivision, smoothing, welding, filling, normals repair or scale fitting",
            "comparison_warning": "Single-asset inspection with its own frame. Not aligned, scaled or registered against LiDAR or Polycam."}


def save(report, directory):
    pending = directory / "inspection.json.pending"
    pending.write_text(json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False) + "\n")
    pending.replace(directory / "inspection.json")


def main():
    args = arguments()
    args.output.mkdir(parents=True, exist_ok=True)
    initial = args.input.stat()
    source_hash = digest(args.input)
    report = {"created_at_utc": datetime.now(timezone.utc).isoformat(), "blender_version": bpy.app.version_string,
              "input": str(args.input), "input_bytes": initial.st_size, "input_sha256_before": source_hash,
              "scope": "Local inventory and native-raster inspection of one completed USDZ. No reconstruction or app/device/UI operations.",
              "not_measured": ["physical dimensional accuracy", "alignment or scale against LiDAR", "iPhone FPS", "Polycam superiority"]}
    report["archive"] = archive_inventory(args.input)
    report["usd_stage"] = stage_inventory(args.input)
    save(report, args.output)
    utils = helpers()
    model, settings = import_asset(args)
    report["import_settings"] = settings
    report["mesh"] = mesh_summary(model, utils, args.topology)
    report["authored_subdivision_warning"] = [mesh["path"] for mesh in report["usd_stage"]["meshes"] if mesh["subdivision_scheme"] not in ("none", "None")]
    save(report, args.output)
    if not args.skip_render:
        report["rendering"] = render_asset(model, args, utils)
    final = args.input.stat()
    report["input_sha256_after"] = digest(args.input)
    report["source_unchanged"] = (report["input_sha256_after"] == source_hash and
        (initial.st_size, initial.st_mtime_ns, initial.st_ino) == (final.st_size, final.st_mtime_ns, final.st_ino))
    save(report, args.output)
    if not report["source_unchanged"]:
        raise ValueError("Source changed during inspection; do not use this report as a final result")
    print("FORMA_USDZ_INSPECTION " + str(args.output / "inspection.json"), flush=True)


if __name__ == "__main__":
    main()
