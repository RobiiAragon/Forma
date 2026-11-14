"""Blender CPU inspection of two meshes in the same ARKit coordinate system.

Run: Blender --background --python Tools/render_mesh_pair.py -- OLD_JSON NEW_JSON OUTPUT
No alignment, smoothing, remeshing, denoising, or source writes.
"""
import bpy
import json
import math
import sys
from pathlib import Path
from mathutils import Vector


def main():
    arguments = sys.argv[sys.argv.index('--') + 1:]
    if len(arguments) != 3:
        raise ValueError('Expected OLD_JSON NEW_JSON NEW_OUTPUT')
    output = Path(arguments[2]); output.mkdir(parents=True, exist_ok=False)
    bpy.ops.object.select_all(action='SELECT'); bpy.ops.object.delete(use_global=False)
    scene = bpy.context.scene
    scene.render.engine = 'CYCLES'; scene.cycles.device = 'CPU'
    scene.cycles.samples = 16; scene.cycles.use_denoising = False
    scene.render.threads_mode = 'FIXED'; scene.render.threads = 2
    scene.render.resolution_x = 900; scene.render.resolution_y = 700
    scene.render.resolution_percentage = 100
    scene.view_settings.view_transform = 'Standard'
    scene.view_settings.exposure = 0; scene.view_settings.gamma = 1
    scene.world.use_nodes = True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value = (.32, .32, .32, 1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value = .7
    material = bpy.data.materials.new('Common neutral geometry inspection')
    material.use_nodes = True
    nodes = material.node_tree.nodes; nodes.clear()
    gray = nodes.new('ShaderNodeBsdfDiffuse'); gray.inputs['Color'].default_value = (.55, .55, .55, 1)
    emission = nodes.new('ShaderNodeEmission')
    emission.inputs['Color'].default_value = (.55, .55, .55, 1)
    emission.inputs['Strength'].default_value = .25
    visible_gray = nodes.new('ShaderNodeAddShader')
    transparent = nodes.new('ShaderNodeBsdfTransparent')
    geometry = nodes.new('ShaderNodeNewGeometry'); mix = nodes.new('ShaderNodeMixShader')
    destination = nodes.new('ShaderNodeOutputMaterial')
    links = material.node_tree.links
    links.new(gray.outputs[0], visible_gray.inputs[0])
    links.new(emission.outputs[0], visible_gray.inputs[1])
    links.new(geometry.outputs['Backfacing'], mix.inputs[0])
    links.new(visible_gray.outputs[0], mix.inputs[1]); links.new(transparent.outputs[0], mix.inputs[2])
    links.new(mix.outputs[0], destination.inputs['Surface'])
    objects = []; coordinates = []; descriptions = []
    for name, filename in zip(['original', 'candidate'], arguments[:2]):
        data = json.loads(Path(filename).read_text())
        # Pure rigid rotation from ARKit Y-up to Blender Z-up.
        vertices = [(v[0], -v[2], v[1]) for v in data['vertices']]
        indices = data['triangles']
        mesh = bpy.data.meshes.new(name)
        mesh.from_pydata(vertices, [], [indices[i:i+3] for i in range(0, len(indices), 3)])
        mesh.update(); obj = bpy.data.objects.new(name, mesh)
        scene.collection.objects.link(obj); mesh.materials.append(material)
        objects.append(obj); coordinates.extend(vertices)
        descriptions.append({'name': name, 'source': str(Path(filename).resolve()),
                             'vertices': len(vertices), 'triangles': len(indices)//3})
    lower = Vector(tuple(min(v[i] for v in coordinates) for i in range(3)))
    upper = Vector(tuple(max(v[i] for v in coordinates) for i in range(3)))
    center = (lower + upper) / 2; diagonal = max((upper-lower).length, .1)
    report = {'models': descriptions, 'sameCoordinatesNoAlignment': True,
              'sameCameraAndLighting': True, 'renderDevice': 'CPU', 'threads': 2,
              'samples': 16, 'denoising': False, 'backFacesHidden': True,
              'commonDiagnosticEmission': .25,
              'scope': 'Neutral geometry inspection, not texture or geometric ground truth.', 'views': []}
    for name, direction in [('oblique', Vector((1.15, -1.55, 1.1))), ('top', Vector((0, -.001, 1)))]:
        data = bpy.data.cameras.new(name); data.type = 'ORTHO'
        camera = bpy.data.objects.new(name, data); scene.collection.objects.link(camera)
        camera.location = center + direction.normalized() * diagonal * 2
        camera.rotation_euler = (center - camera.location).to_track_quat('-Z', 'Y').to_euler()
        inverse = camera.rotation_euler.to_matrix().transposed()
        projected = [inverse @ (Vector(v) - camera.location) for v in coordinates]
        width = 2*max(abs(p.x) for p in projected)
        height = 2*max(abs(p.y) for p in projected)
        aspect = scene.render.resolution_x/scene.render.resolution_y
        data.ortho_scale = max(width, height*aspect)*1.12
        data.clip_start = .001; data.clip_end = diagonal*10
        scene.camera = camera
        light_data = bpy.data.lights.new(name, 'AREA'); light_data.energy = 150
        light_data.shape = 'DISK'; light_data.size = diagonal*.8
        light = bpy.data.objects.new(name+' light', light_data); scene.collection.objects.link(light)
        light.location = camera.location; light.rotation_euler = camera.rotation_euler
        for obj in objects:
            for other in objects: other.hide_render = other != obj
            scene.render.filepath = str(output / (obj.name+'_'+name+'.png'))
            bpy.ops.render.render(write_still=True)
        report['views'].append({'name': name, 'cameraLocation': list(camera.location),
                                'rotation': list(camera.rotation_euler), 'orthoScale': data.ortho_scale})
        bpy.data.objects.remove(light, do_unlink=True)
        del projected
    (output/'inspection.json').write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
