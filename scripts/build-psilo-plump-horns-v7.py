"""Enlarge and round the validated circular horns on the v6 review model."""
import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, required=True)
parser.add_argument('--draft', action='store_true')
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
out = args.out.resolve()
if out.exists() and any(out.iterdir()):
    raise ValueError('Use a new empty output directory')
out.mkdir(parents=True, exist_ok=True)
scripts = Path(__file__).resolve().parent
scope = {'__name__': 'psilo_v7_helpers'}

def helper(name):
    path = scripts / name
    exec(compile(path.read_text(), str(path), 'exec'), scope)

scene = bpy.context.scene
helper('psilo-motion-v2.py')
scope['restore_psilo_rest'](scene)
helper('psilo-horn-socket-v6.py')
report = scope['fit_horn_sockets_v6'](
    scene, surface_anchor=(.057, .026), base_inset=.006,
    base_z=0, virtual_tip_z=.035, base_radius=.018, tip_round_radius=.0025)
helper('psilo-horn-lighting-v6.py')
report['lighting'] = scope['apply_horn_lighting_v6'](scene)
report['change'] = 'Larger circular cones with a broader spherical tip; same root anchor and surface-normal alignment'
report['previous_dimensions_m'] = {'base_radius': .014, 'virtual_height': .030, 'tip_round_radius': .0008}
report['production_replaced'] = False
for texture in bpy.data.images:
    if texture.name not in ('Render Result', 'Viewer Node'):
        if not texture.packed_file:
            texture.pack()
        if texture.filepath:
            texture.filepath = '//' + Path(texture.filepath).name

scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 24 if args.draft else 64
scene.cycles.use_denoising = True
scene.render.resolution_x = 1000
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
scene.render.threads_mode = 'FIXED'
scene.render.threads = 6
scene.render.film_transparent = True

def view(angle=0, wide=False):
    radians = math.radians(angle)
    camera = scene.camera
    camera.location = (.45 * math.sin(radians), -.45 * math.cos(radians), .105)
    camera.rotation_euler = (Vector((0, 0, .100 if wide else .077)) - camera.location).to_track_quat('-Z', 'Y').to_euler()
    camera.data.ortho_scale = .34 if wide else .25

def render(name):
    scene.render.filepath = str(out / (name + '.png'))
    bpy.ops.render.render(write_still=True)

view()
scene.render.filepath = '//front.png'
bpy.ops.wm.save_as_mainfile(filepath=str(out / 'Psilo-v7.blend'))
for name, angle in [('front', 0), ('left', -35), ('right', 35)]:
    view(angle)
    render(name)
    if args.draft and name == 'left':
        break
if not args.draft:
    scope['animate_psilo'](scene, anchored_horns=True, inset_mouth=True)
    horns = scene.objects['Horns']
    horns.animation_data_clear()
    horns.rotation_mode = 'QUATERNION'
    horns.rotation_quaternion = (1, 0, 0, 0)
    horns.location = Vector(horns['psilo_review_rest_location'])
    horns.scale = Vector(horns['psilo_review_rest_scale'])
    view(wide=True)
    for name, frame in [('working', 88), ('proud', 141), ('error', 207), ('transition', 210)]:
        scene.frame_set(frame)
        render(name)
    scene.frame_set(1)
    view()
    scene.render.filepath = '//front.png'
    bpy.ops.wm.save_as_mainfile(filepath=str(out / 'Psilo-v7-motion.blend'))
(out / 'build-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
