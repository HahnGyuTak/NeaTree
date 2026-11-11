"""Bake the latest Psilo into a separately validated runtime candidate.

Load review-v7-plump-horns/Psilo-v7.blend first. The script never installs app
resources or overwrites a review source. Mac 15+ uses USD blend shapes; matching
target meshes provide an explicitly named Mac 14 buffer-interpolation fallback.
"""
import argparse
import hashlib
import json
import math
import re
import subprocess
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector
from mathutils.bvhtree import BVHTree

P = argparse.ArgumentParser()
P.add_argument('--out', type=Path, required=True)
P.add_argument('--triangles', type=int, default=40000)
P.add_argument('--texture-size', type=int, default=2048)
P.add_argument('--lod-input', type=Path)
P.add_argument('--source-metadata', type=Path)
P.add_argument('--draft', action='store_true')
A = P.parse_args(sys.argv[sys.argv.index('--') + 1:])
OUT = A.out.resolve()
if OUT.exists() and any(OUT.iterdir()):
    raise ValueError('Choose a new empty candidate directory.')
OUT.mkdir(parents=True, exist_ok=True)
SCRIPTS = Path(__file__).resolve().parent
SOURCE = 'assets/psilo/review-v7-plump-horns/Psilo-v7.blend'
HELPERS = {'__name__': 'runtime_helpers'}


def helper(name):
    path = SCRIPTS / name
    exec(compile(path.read_text(), str(path), 'exec'), HELPERS)



def finite_points(points, context):
    if any(not all(math.isfinite(value) for value in point) for point in points):
        raise ValueError('Nonfinite geometry: ' + context)


def stable_smile_transfer(obj, sample):
    """Transfer tiny evaluated triangles with normalized double-precision scalars.

    mathutils barycentric_transform can overflow on submillimetre triangles;
    source/target delta interpolation avoids translating nearly identical points.
    """
    neutral, target, triangles = sample['neutral'], sample['target'], sample['triangles']
    finite_points(neutral, 'source cap Basis')
    finite_points(target, 'source cap SmileClose')
    tree = BVHTree.FromPolygons(neutral, triangles, all_triangles=True)
    if not obj.data.shape_keys:
        obj.shape_key_add(name='Basis', from_mix=False)
    key = obj.data.shape_keys.key_blocks.get('SmileClose') or obj.shape_key_add(name='SmileClose', from_mix=False)
    max_projection = 0.0
    moved = 0
    degenerate_triangles = 0
    for vertex in obj.data.vertices:
        projected, normal, index, distance = tree.find_nearest(vertex.co)
        if index is None:
            raise ValueError('Missing cap triangle for morph transfer.')
        indices = triangles[index]
        a, b, c = [tuple(neutral[i]) for i in indices]
        edge0 = [b[j] - a[j] for j in range(3)]
        edge1 = [c[j] - a[j] for j in range(3)]
        p = [float(projected[j]) - a[j] for j in range(3)]
        scale = max(abs(x) for x in edge0 + edge1)
        if scale <= 1e-20:
            raise ValueError('Degenerate cap triangle in morph transfer.')
        edge0, edge1, p = [[x / scale for x in v] for v in (edge0, edge1, p)]
        dot = lambda x, y: sum(a * b for a, b in zip(x, y))
        aa, ab, bb = dot(edge0, edge0), dot(edge0, edge1), dot(edge1, edge1)
        pa, pb = dot(p, edge0), dot(p, edge1)
        det = aa * bb - ab * ab
        if det <= 1e-16:
            # Latitude poles contain zero-area triangles. Their continuous
            # displacement is well-defined along the longest surviving edge.
            degenerate_triangles += 1
            pairs = [(0, 1), (0, 2), (1, 2)]
            positions = [a, b, c]
            ia, ib = max(pairs, key=lambda pair: sum((positions[pair[0]][j] - positions[pair[1]][j])**2 for j in range(3)))
            start, end = positions[ia], positions[ib]
            edge = [end[j] - start[j] for j in range(3)]
            length2 = dot(edge, edge)
            fraction = min(1.0, max(0.0, sum((float(projected[j]) - start[j]) * edge[j] for j in range(3)) / length2))
            weights = [0.0, 0.0, 0.0]
            weights[ia], weights[ib] = 1 - fraction, fraction
        else:
            wb, wc = (bb * pa - ab * pb) / det, (aa * pb - ab * pa) / det
            weights = [max(0.0, min(1.0, w)) for w in (1 - wb - wc, wb, wc)]
        total = sum(weights)
        weights = [w / total for w in weights]
        delta = Vector(tuple(sum(weights[k] * (float(target[i][j]) - float(neutral[i][j]))
                                 for k, i in enumerate(indices)) for j in range(3)))
        key.data[vertex.index].co = vertex.co + delta
        max_projection = max(max_projection, distance)
        moved += delta.length > 1e-7
    finite_points([v.co for v in key.data], 'transferred cap SmileClose')
    key.value = 0
    return {'object': obj.name, 'name': 'SmileClose', 'method': 'normalized double-precision barycentric displacement',
            'vertices': len(key.data), 'moved_vertices': moved, 'max_local_projection_distance_units': max_projection,
            'nonfinite_vertices': 0, 'degenerate_triangle_edge_samples': degenerate_triangles}



def clean_path_buffer(owner, name, value):
    # Blender's fixed-size DNA strings can retain old bytes after a shorter
    # value's NUL terminator. Overwrite the declared buffer before assigning it.
    capacity = owner.bl_rna.properties[name].length_max
    if capacity:
        filler = 'x' * (capacity - 1)
        setattr(owner, name, filler.encode() if isinstance(value, bytes) else filler)
    setattr(owner, name, value)


def sanitize_authoring_paths():
    """Keep packed authoring copies portable without exposing workstation paths."""
    for image in bpy.data.images:
        if image.packed_files:
            image.use_fake_user = True
            if image.filepath:
                clean_path_buffer(image, 'filepath', '//' + Path(image.filepath).name)
            for packed in image.packed_files:
                clean_path_buffer(packed, 'filepath', '//' + Path(packed.filepath).name)
    for scene in bpy.data.scenes:
        scene.render.use_stamp_filename = False
        scene.render.use_stamp_note = False
        scene.render.stamp_note_text = ''
        if scene.render.filepath and not scene.render.filepath.startswith('//'):
            clean_path_buffer(scene.render, 'filepath', '//render.png')
    for screen in bpy.data.screens:
        for area in screen.areas:
            for space in area.spaces:
                if space.type == 'FILE_BROWSER' and space.params:
                    clean_path_buffer(space.params, 'directory', b'//')
                    clean_path_buffer(space.params, 'filename', '')


def count_triangles(mesh):
    mesh.calc_loop_triangles()
    return len(mesh.loop_triangles)


def select_only(objects):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.hide_set(False)
        obj.hide_viewport = False
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]


def render(scene, name, angle=0, wide=False):
    camera = scene.camera
    a = math.radians(angle)
    camera.location = (.45 * math.sin(a), -.45 * math.cos(a), .105)
    camera.rotation_euler = (Vector((0, 0, .100 if wide else .077)) - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.ortho_scale = .34 if wide else .25
    scene.render.filepath = str(OUT / (name + '.png'))
    bpy.ops.render.render(write_still=True)


scene = bpy.context.scene
sanitize_authoring_paths()
if A.lod_input:
    metadata = json.loads(A.source_metadata.read_text()) if A.source_metadata else {}
    colors = metadata.get('colors', metadata)
    bpy.ops.wm.open_mainfile(filepath=str(A.lod_input.resolve()))
else:
    colors = {o.name: list(o.color) for o in scene.objects}
    metadata = {'colors': colors, 'source': SOURCE}
    (OUT / 'source-metadata.json').write_text(json.dumps(metadata, indent=2) + '\n')
    for name in ('MouthCavity', 'MouthLowerGlow', 'SmileBacking'):
        obj = scene.objects.get(name)
        if obj:
            bpy.data.objects.remove(obj, do_unlink=True)
    # The neutral authoring curve deliberately has zero bevel. Export its full
    # finished shape; the runtime reveals it through the mouth_proud control.
    scene.objects['Smile'].data.bevel_depth = .00065
    helper('psilo-runtime-lod.py')
    HELPERS['transfer_smile_shape'] = stable_smile_transfer
    HELPERS['create_lod'](scene, OUT / 'Psilo-lod.blend', A.triangles, OUT / 'Psilo-lod-studio.blend')
    bpy.ops.wm.open_mainfile(filepath=str(OUT / 'Psilo-lod-studio.blend'))

scene = bpy.context.scene
scene.frame_set(1)
# Library-copy studio objects carry Blender's .001 suffix; restore their public
# names before rebinding receiver rules to the newly decimated character.
for obj in list(scene.objects):
    if obj.name.startswith('STUDIO_') and '.' in obj.name:
        base = obj.name.split('.')[0]
        previous = bpy.data.objects.get(base)
        if previous and previous != obj:
            previous.name = '__unused_' + base
        obj.name = base
for name, color in colors.items():
    if name in scene.objects:
        scene.objects[name].color = color
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 24 if A.draft else 64
scene.cycles.use_denoising = True
scene.render.threads_mode = 'FIXED'
scene.render.threads = 6
scene.render.resolution_x = 1000
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.render.use_stamp_filename = False
scene.render.use_stamp_note = False
scene.view_layers[0].update()
# Rebind studio receivers to the new LOD objects, rather than authoring copies.
for light_name in ('STUDIO_Fill', 'STUDIO_LowFill'):
    light = scene.objects.get(light_name)
    if light:
        light.light_linking.receiver_collection = None
bounce = scene.objects.get('STUDIO_BodyBounce')
if bounce:
    receivers = bpy.data.collections.new('Runtime body bounce receivers')
    receivers.objects.link(scene.objects['Pedestal'])
    bounce.light_linking.receiver_collection = receivers
helper('psilo-horn-lighting-v6.py')
HELPERS['apply_horn_lighting_v6'](scene)

cap = scene.objects['Cap']
# Decimation interpolates arbitrary loop normals at the conical tip. Rebuild
# exact cone/sphere normals from the approved analytic shape, without changing
# any vertices, so a low triangle count does not introduce diagonal highlights.
horn_spec = json.loads((SCRIPTS.parent / 'assets/psilo/review-v7-plump-horns/build-manifest.json').read_text())
for spec in horn_spec['horns']:
    obj = scene.objects[spec['horn']]
    axis = Vector(spec['axis_cap']).normalized()
    base = Vector(spec['base_center_cap'])
    height = spec['virtual_height_m']
    radius = spec['base_radius_m']
    tip_radius = spec['tip_round_radius_m']
    angle = math.atan(radius / height)
    join_height = height - tip_radius * math.cos(angle)**2 / math.sin(angle)
    sphere = base + axis * (height - tip_radius / math.sin(angle))
    normals = []
    for polygon in obj.data.polygons:
        basal = all(abs((obj.data.vertices[i].co-base).dot(axis)) < 1e-6 for i in polygon.vertices)
        polygon.use_smooth = True
        for loop in polygon.loop_indices:
            point = obj.data.vertices[obj.data.loops[loop].vertex_index].co
            delta = point - base
            axial = delta.dot(axis)
            if basal:
                normal = -axis
            elif axial >= join_height - 1e-8:
                normal = (point - sphere).normalized()
            else:
                radial = (delta - axis * axial).normalized()
                normal = radial * math.cos(angle) + axis * math.sin(angle)
            normals.append(tuple(normal))
    obj.data.normals_split_custom_set(normals)
cap_key = cap.data.shape_keys.key_blocks['SmileClose']
finite_points([v.co for v in cap_key.data], 'runtime cap SmileClose')
cap_key.value = 0
render(scene, 'lod-procedural-front')

# Bake the cap's paper without the dynamically shrinking mouth pigment. That
# pigment gets its own inset, surface-following mesh and closure morph below.
cap_mat = cap.data.materials[0]
nodes, links = cap_mat.node_tree.nodes, cap_mat.node_tree.links
shader = next(n for n in nodes if n.type == 'BSDF_PRINCIPLED')
mouth_mix = nodes.get('Inset cavity pigment follows SmileClose')
if mouth_mix is None or not mouth_mix.inputs[1].is_linked:
    raise ValueError('Expected the v7 inset-mouth authoring shader.')
links.new(mouth_mix.inputs[1].links[0].from_socket, shader.inputs['Base Color'])


def cap_surface(x, z):
    evaluated = cap.evaluated_get(bpy.context.evaluated_depsgraph_get())
    hit, position, normal, _ = evaluated.ray_cast(Vector((x, -.25, z)), Vector((0, 1, 0)))
    if not hit:
        raise ValueError('Mouth sample does not intersect cap.')
    return position, normal.normalized()


center = cap.matrix_world.inverted() @ scene.objects['mouth_idle'].matrix_world.translation
segments, rings = 64, 10
samples = [(0.0, 0.0)]
for ring in range(1, rings + 1):
    radius = ring / rings
    for segment in range(segments):
        theta = 2 * math.pi * segment / segments
        samples.append((radius * math.cos(theta), radius * math.sin(theta)))
neutral = []
for x, z in samples:
    point, normal = cap_surface(center.x + .00585 * x, center.z + .0039 * z)
    neutral.append(point + normal * .000025)
cap_key.value = 1
scene.view_layers[0].update()
closed = []
for x, z in samples:
    point, normal = cap_surface(center.x + .00585 * x * .65, center.z)
    closed.append(point + normal * .000025)
cap_key.value = 0
scene.view_layers[0].update()
faces = []
for j in range(segments):
    faces.append((0, 1 + j, 1 + (j + 1) % segments))
for ring in range(rings - 1):
    for j in range(segments):
        a = 1 + ring * segments + j
        b = 1 + ring * segments + (j + 1) % segments
        faces.append((a, a + segments, b + segments, b))
mesh = bpy.data.meshes.new('MouthInteriorSurface')
mesh.from_pydata(neutral, [], faces)
mesh.update()
mouth = bpy.data.objects.new('MouthInterior', mesh)
scene.collection.objects.link(mouth)
mouth.parent = cap.parent
mouth.matrix_local = cap.matrix_local.copy()
for polygon in mesh.polygons:
    polygon.use_smooth = True
mouth.shape_key_add(name='Basis')
key = mouth.shape_key_add(name='SmileClose')
for vertex, point in zip(key.data, closed):
    vertex.co = point
key.value = 0
mouth_mat = bpy.data.materials.new('MouthInteriorBake')
mouth_mat.use_nodes = True
ms = mouth_mat.node_tree.nodes.get('Principled BSDF')
ms.inputs['Roughness'].default_value = .82
ms.inputs['Specular IOR Level'].default_value = .12
mn, ml = mouth_mat.node_tree.nodes, mouth_mat.node_tree.links
tc = mn.new('ShaderNodeTexCoord')
separate = mn.new('ShaderNodeSeparateXYZ')
ml.new(tc.outputs['Object'], separate.inputs['Vector'])
lower = mn.new('ShaderNodeMapRange')
lower.clamp = True
lower.inputs['From Min'].default_value = center.z + .0003
lower.inputs['From Max'].default_value = center.z - .0035
ml.new(separate.outputs['Z'], lower.inputs['Value'])
mix = mn.new('ShaderNodeMixRGB')
mix.inputs[1].default_value = (.030, .004, .002, 1)
mix.inputs[2].default_value = (.200, .030, .012, 1)
ml.new(lower.outputs['Result'], mix.inputs[0])
ml.new(mix.outputs[0], ms.inputs['Base Color'])
mouth.data.materials.append(mouth_mat)

rectangles = {
    'Cap': (0, 0, .70, .70), 'Brim': (.70, 0, 1, .30),
    'Crown': (.70, .30, 1, .60), 'Band': (.70, .60, 1, .70),
    'Pedestal': (0, .70, .40, 1), 'Horn_L': (.40, .70, .60, .90),
    'Horn_R': (.60, .70, .80, .90), 'MouthInterior': (.40, .90, .60, 1),
    'Document': (.80, .70, 1, .80), 'Folder': (.80, .80, 1, .90),
    'FolderTab': (.80, .90, 1, 1),
}
paper = []
for obj in list(scene.objects):
    if obj.type != 'MESH' or obj.name.startswith('STUDIO_'):
        continue
    if all(mat.name == 'Ink' for mat in obj.data.materials):
        continue
    base_name = obj.name.split('.')[0]
    if base_name not in rectangles:
        raise ValueError('Unmapped paper mesh: ' + obj.name)
    paper.append(obj)
    select_only([obj])
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=.035)
    bpy.ops.object.mode_set(mode='OBJECT')
    obj.data.uv_layers.active.name = 'UVMap'
    x0, y0, x1, y1 = rectangles[base_name]
    padding = 12 / A.texture_size
    for uv in obj.data.uv_layers.active.data:
        uv.uv = (x0 + padding + uv.uv.x * (x1 - x0 - 2 * padding),
                 y0 + padding + uv.uv.y * (y1 - y0 - 2 * padding))

textures = {}
for label, bake_type, size, colorspace in [
    ('Color', 'DIFFUSE', A.texture_size, 'sRGB'),
    ('Roughness', 'ROUGHNESS', min(1024, A.texture_size), 'Non-Color'),
    ('Normal', 'NORMAL', min(1024, A.texture_size), 'Non-Color'),
]:
    image = bpy.data.images.new('Psilo-v7-' + label, width=size, height=size, alpha=False)
    image.colorspace_settings.name = colorspace
    image.generated_color = (.5, .5, 1, 1) if label == 'Normal' else (0, 0, 0, 1)
    image.filepath_raw = str(OUT / ('Psilo-v7-' + label.lower() + '.png'))
    image.file_format = 'PNG'
    for mat in {m for obj in paper for m in obj.data.materials}:
        node = mat.node_tree.nodes.get('Runtime atlas bake target') or mat.node_tree.nodes.new('ShaderNodeTexImage')
        node.name = 'Runtime atlas bake target'
        node.image = image
        mat.node_tree.nodes.active = node
    for obj in paper:
        # Identical file copies share atlas islands and authored materials.
        if '.' in obj.name:
            continue
        select_only([obj])
        # Bake the cap with its cavity closed. Otherwise the authoring material's
        # normal-based underside pigment records a reddish hollow on the skin
        # forever, even after its mesh closes. The fitted MouthInterior supplies
        # the open cavity pigment, while this texture stays clean during smiles.
        if obj == cap:
            cap_key.value = 1
            scene.view_layers[0].update()
        scene.render.bake.use_clear = False
        scene.render.bake.margin = max(3, round(size / 256))
        options = {'type': bake_type, 'use_clear': False, 'margin': scene.render.bake.margin}
        if bake_type == 'DIFFUSE':
            options['pass_filter'] = {'COLOR'}
        bpy.ops.object.bake(**options)
        if obj == cap:
            cap_key.value = 0
            scene.view_layers[0].update()
        print('BAKED', label, obj.name, flush=True)
    image.save()
    textures[label] = image

runtime = bpy.data.materials.new('Psilo Paper Atlas v7')
runtime.use_nodes = True
rn, rl = runtime.node_tree.nodes, runtime.node_tree.links
rs = rn.get('Principled BSDF')
rs.inputs['Specular IOR Level'].default_value = .12
rs.inputs['Subsurface Weight'].default_value = 0
rs.inputs['Metallic'].default_value = 0
for label, socket in [('Color', 'Base Color'), ('Roughness', 'Roughness')]:
    tex = rn.new('ShaderNodeTexImage')
    tex.name = 'Baked ' + label
    tex.image = textures[label]
    rl.new(tex.outputs['Color'], rs.inputs[socket])
normal_tex = rn.new('ShaderNodeTexImage')
normal_tex.name = 'Baked Normal'
normal_tex.image = textures['Normal']
normal_map = rn.new('ShaderNodeNormalMap')
rl.new(normal_tex.outputs['Color'], normal_map.inputs['Color'])
rl.new(normal_map.outputs['Normal'], rs.inputs['Normal'])
for obj in paper:
    obj.data.materials.clear()
    obj.data.materials.append(runtime)
    for polygon in obj.data.polygons:
        polygon.material_index = 0

render(scene, 'baked-front')
render(scene, 'baked-left', -35)
render(scene, 'baked-right', 35)
for amount in (.5, 1):
    cap_key.value = amount
    mouth.data.shape_keys.key_blocks['SmileClose'].value = amount
    for name in ('EyeDot_L', 'EyeDot_R'):
        scene.objects[name].data.shape_keys.key_blocks['Happy'].value = amount
    scene.objects['mouth_proud'].scale = (1, 1, 1) if amount == 1 else (.001, .001, .001)
    render(scene, 'smile-' + str(amount))
cap_key.value = 0
mouth.data.shape_keys.key_blocks['SmileClose'].value = 0
for name in ('EyeDot_L', 'EyeDot_R'):
    scene.objects[name].data.shape_keys.key_blocks['Happy'].value = 0
scene.objects['mouth_proud'].scale = (.001, .001, .001)
scene.view_layers[0].update()
for image in textures.values():
    image.pack()
    image.filepath = '//' + Path(image.filepath).name
sanitize_authoring_paths()
scene.render.filepath = '//baked-front.png'
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / 'Psilo-v7-runtime-studio.blend'))

# Export all local bases, including shape deltas, into Y-up/+Z-front explicitly.
# A root-only rotation would make the app's per-control axes incorrect.
root = scene.objects['Psilo']
objects = [root] + list(root.children_recursive)
visible_triangles = sum(count_triangles(o.data) for o in objects if o.type == 'MESH')
targets = bpy.data.objects.new('PsiloMorphTargets', None)
scene.collection.objects.link(targets)
targets.parent = root
targets.scale = (.001, .001, .001)
target_report = []
for name, shape in [('Cap', 'SmileClose'), ('EyeDot_L', 'Happy'), ('EyeDot_R', 'Happy'), ('MouthInterior', 'SmileClose')]:
    source = scene.objects[name]
    mesh = source.data.copy()
    target = bpy.data.objects.new('MorphTarget_' + name + '_' + shape, mesh)
    scene.collection.objects.link(target)
    target.parent = targets
    points = [v.co.copy() for v in mesh.shape_keys.key_blocks[shape].data]
    target.shape_key_clear()
    for vertex, point in zip(mesh.vertices, points):
        vertex.co = point
    mesh.update()
    finite_points([v.co for v in mesh.vertices], target.name)
    target_report.append({'source': name, 'shape': shape, 'target': target.name,
                          'vertices': len(mesh.vertices), 'triangles': count_triangles(mesh)})
objects = [root] + list(root.children_recursive)
conversion = Matrix.Rotation(-math.pi / 2, 4, 'X')
inverse = conversion.inverted()
transforms = {o: o.matrix_local.copy() for o in objects}
for obj in objects:
    if obj.type == 'MESH':
        obj.data.transform(conversion, shape_keys=True)
    obj.matrix_local = conversion @ transforms[obj] @ inverse
    if obj.type == 'MESH':
        obj.data.update()
        finite_points([v.co for v in obj.data.vertices], obj.name + ' mesh')
        if obj.data.shape_keys:
            for key in obj.data.shape_keys.key_blocks:
                finite_points([v.co for v in key.data], obj.name + '.' + key.name)
select_only(objects)
scene.view_layers[0].update()
properties = bpy.ops.wm.usd_export.get_rna_type().properties
options = dict(filepath=str(OUT / 'Psilo-app.usda'), selected_objects_only=True,
               visible_objects_only=False, export_animation=False, export_materials=True,
               export_textures=True, export_textures_mode='NEW', overwrite_textures=True,
               export_normals=True, export_uvmaps=True, export_meshes=True,
               export_shapekeys=True, export_armatures=True, export_cameras=False,
               export_lights=False, generate_materialx_network=False,
               convert_orientation=False, root_prim_path='/root')
bpy.ops.wm.usd_export(**{key: value for key, value in options.items() if key in properties})
stage = OUT / 'Psilo-app.usda'
stage_text = stage.read_text().replace('upAxis = "Z"', 'upAxis = "Y"', 1).rstrip() + '\n'
if re.search(r'(?<![A-Za-z_])(?:-?nan|-?inf)(?=[,\s\)])', stage_text, re.IGNORECASE):
    raise ValueError('USD export contains a nonfinite numeric value.')
stage.write_text(stage_text)
subprocess.run(['usdcat', str(stage), '-o', str(OUT / 'Psilo.usdc')], check=True)
subprocess.run(['usdzip', '--asset', str(OUT / 'Psilo.usdc'), str(OUT / 'Psilo.usdz')], check=True)
subprocess.run(['usdchecker', '--arkit', str(OUT / 'Psilo.usdz')], check=True)
metrics = {'source': SOURCE,
           'source_sha256': hashlib.sha256((SCRIPTS.parent / SOURCE).read_bytes()).hexdigest(),
           'build_script_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
           'blender_version': bpy.app.version_string,
           'visible_triangles': visible_triangles,
           'fallback_target_triangles': sum(t['triangles'] for t in target_report),
           'fallback_targets': target_report,
           'material_count': len({m.name for obj in objects if obj.type == 'MESH' for m in obj.data.materials}),
           'textures': [{'name': Path(i.filepath).name, 'size': list(i.size)} for i in textures.values()],
           'usdz_bytes': (OUT / 'Psilo.usdz').stat().st_size,
           'usdz_sha256': hashlib.sha256((OUT / 'Psilo.usdz').read_bytes()).hexdigest(),
           'installed_in_app': False, 'native_runtime_visual_validation_pending': True,
           'mouth': 'fitted inset surface patch with closure blendshape; closed aperture collapses to zero area',
           'coordinate_system': 'Y-up, +Z front; converted per mesh/control/shape key'}
(OUT / 'model-metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
print('RUNTIME_V7_COMPLETE', json.dumps(metrics), flush=True)
