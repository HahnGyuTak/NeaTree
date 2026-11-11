"""Apply approved v5 horns to an existing Psilo scene, preserving other parts.

Use a new empty output directory. This creates review or runtime candidates;
copying a validated runtime candidate into app resources is a separate step.
  blender -b SOURCE.blend --python scripts/build-psilo-short-horns-v5.py \
      -- --out /tmp/new-output --kind review
Kinds: review (v4 source and continuous preview), runtime (existing app source).
"""
import argparse
import bpy
import hashlib
import json
import math
import struct
import subprocess
import sys
from pathlib import Path
from mathutils import Matrix, Vector

parser = argparse.ArgumentParser()
parser.add_argument('--out', required=True, type=Path)
parser.add_argument('--kind', choices=['review', 'runtime'], required=True)
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
out = args.out.resolve()
if out.exists() and any(out.iterdir()):
    raise ValueError('Use a new empty output directory to preserve existing assets.')
out.mkdir(parents=True, exist_ok=True)
scripts = Path(__file__).resolve().parent
scope = {'__name__': 'psilo_horn_build_helpers'}
exec(compile((scripts / 'psilo-short-horns-v5.py').read_text(), 'horn_helper', 'exec'), scope)
scene = bpy.context.scene
scene.frame_set(1)


def fingerprint(obj):
    digest = hashlib.sha256()
    digest.update(obj.type.encode())
    digest.update((obj.parent.name if obj.parent else '').encode())
    for row in obj.matrix_local:
        for v in row:
            digest.update(struct.pack('d', v))
    if obj.type == 'MESH':
        for v in obj.data.vertices:
            digest.update(struct.pack('ddd', *v.co))
        for poly in obj.data.polygons:
            digest.update(str(tuple(poly.vertices)).encode())
        if obj.data.shape_keys:
            for key in obj.data.shape_keys.key_blocks:
                digest.update(key.name.encode())
                for v in key.data:
                    digest.update(struct.pack('ddd', *v.co))
    elif obj.type == 'CURVE':
        for spline in obj.data.splines:
            for p in spline.bezier_points:
                digest.update(struct.pack('ddd', *p.co))
    return digest.hexdigest()


before = {o.name: fingerprint(o) for o in scene.objects if o.name not in ('Horn_L', 'Horn_R')}
if args.kind == 'review':
    detail = scope['apply_psilo_short_horns_v5'](scene)
else:
    detail = scope['apply_psilo_short_horns_v5'](scene, segments=24, rings=17,
                                             subdivision=1, front_offset=-.003)
after = {o.name: fingerprint(o) for o in scene.objects if o.name not in ('Horn_L', 'Horn_R')}
assert before == after, 'Only the two horns may change.'
detail['non_horn_objects_unchanged'] = len(before)
detail['kind'] = args.kind
detail['approved_reference'] = 'assets/psilo/reference/short-horns-approved-v1.png'

for image in bpy.data.images:
    if image.name in ('Render Result', 'Viewer Node'):
        continue
    if not image.packed_file:
        image.pack()
    if image.filepath:
        image.filepath = '//' + Path(image.filepath).name
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 32 if args.kind == 'review' else 24
scene.render.resolution_x = 1000 if args.kind == 'review' else 900
scene.render.resolution_y = 900 if args.kind == 'review' else 810
scene.render.threads_mode = 'FIXED'
scene.render.threads = 6
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
cam = scene.camera
camera_rest = cam.matrix_world.copy()
scale_rest = cam.data.ortho_scale


def view(angle=0, wide=False):
    rad = math.radians(angle)
    cam.location = (.45 * math.sin(rad), -.45 * math.cos(rad), .105)
    cam.rotation_euler = (Vector((0, 0, .100 if wide else .077)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
    cam.data.ortho_scale = .34 if wide else .25


def render(name):
    scene.render.filepath = str(out / (name + '.png'))
    bpy.ops.render.render(write_still=True)


view()
scene.render.filepath = '//front.png'
source_name = 'Psilo-v5.blend' if args.kind == 'review' else 'Psilo.blend'
bpy.ops.wm.save_as_mainfile(filepath=str(out / source_name))
angles = [('front', 0), ('left', -35), ('right', 35)] if args.kind == 'review' else [('front', 0), ('left', -35)]
for name, angle in angles:
    view(angle)
    render(name)

if args.kind == 'review':
    exec(compile((scripts / 'psilo-motion-v2.py').read_text(), 'motion_helper', 'exec'), scope)
    scope['animate_psilo'](scene)
    view(wide=True)
    for name, frame in [('working', 88), ('proud', 141), ('error', 207), ('transition', 210)]:
        scene.frame_set(frame)
        render(name)
    scene.frame_set(1)
    view()
    scene.render.filepath = '//front.png'
    bpy.ops.wm.save_as_mainfile(filepath=str(out / 'Psilo-v5-motion.blend'))
    detail['motion_frames'] = [scene.frame_start, scene.frame_end]
else:
    # Existing app model is exported at its original neutral frame. Native
    # authoring remains Z-up; every local geometry/control basis converts to
    # app Y-up,+Z front, preserving the runtime spring driver's named hierarchy.
    scene.frame_set(1)
    root = scene.objects['Psilo']
    sources = [root] + list(root.children_recursive)
    names = {obj: obj.name for obj in sources}
    for obj in sources:
        obj.name = 'AUTHOR_' + names[obj]
    conversion = Matrix.Rotation(-math.pi / 2, 4, 'X')
    inverse = conversion.inverted()
    deps = bpy.context.evaluated_depsgraph_get()
    copies = {}
    for obj in sources:
        if obj.type in {'MESH', 'CURVE'}:
            data = bpy.data.meshes.new_from_object(obj.evaluated_get(deps), depsgraph=deps)
            data.transform(conversion)
            new = bpy.data.objects.new(names[obj], data)
        else:
            new = bpy.data.objects.new(names[obj], None)
        scene.collection.objects.link(new)
        copies[obj] = new
    for obj, new in copies.items():
        new.parent = copies.get(obj.parent)
        new.matrix_local = conversion @ obj.matrix_local @ inverse
    bpy.ops.object.select_all(action='DESELECT')
    for obj in copies.values():
        obj.select_set(True)
    scene.view_layers[0].objects.active = copies[root]
    props = bpy.ops.wm.usd_export.get_rna_type().properties
    kwargs = dict(filepath=str(out / 'Psilo-app.usda'), selected_objects_only=True,
                  export_animation=False, export_materials=True, export_textures=True,
                  overwrite_textures=True, export_normals=True, export_uvmaps=True,
                  export_meshes=True, export_cameras=False, export_lights=False,
                  generate_materialx_network=False, convert_orientation=False)
    bpy.ops.wm.usd_export(**{k: v for k, v in kwargs.items() if k in props})
    stage = out / 'Psilo-app.usda'
    stage.write_text(stage.read_text().replace('upAxis = "Z"', 'upAxis = "Y"', 1).rstrip() + '\n')
    subprocess.run(['usdcat', str(stage), '-o', str(out / 'Psilo.usdc')], check=True)
    subprocess.run(['usdzip', '--asset', str(out / 'Psilo.usdc'), str(out / 'Psilo.usdz')], check=True)
    subprocess.run(['usdchecker', '--arkit', str(out / 'Psilo.usdz')], check=True)
    triangles = 0
    mesh_count = 0
    for obj in copies.values():
        if obj.type == 'MESH':
            obj.data.calc_loop_triangles()
            triangles += len(obj.data.loop_triangles)
            mesh_count += 1
    metrics = {'name': 'Psilo', 'source': 'Blender 5.3', 'horn_design': 'approved-short-soft-point-v5',
               'triangles': triangles, 'meshes': mesh_count, 'materials': 6,
               'textures': 1, 'texture_resolution': [768, 768],
               'bytes': (out / 'Psilo.usdz').stat().st_size}
    (out / 'model-metrics.json').write_text(json.dumps(metrics, indent=2) + '\n')
    detail['runtime_metrics'] = metrics
    for obj in copies.values():
        bpy.data.objects.remove(obj, do_unlink=True)
    for obj, name in names.items():
        obj.name = name
    cam.matrix_world = camera_rest
    cam.data.ortho_scale = scale_rest
    scene.render.filepath = '//Psilo-front.png'
    bpy.ops.wm.save_as_mainfile(filepath=str(out / 'Psilo.blend'))

(out / 'horn-update-report.json').write_text(json.dumps(detail, indent=2) + '\n')
print('PSILO_HORN_UPDATE ' + json.dumps(detail))
