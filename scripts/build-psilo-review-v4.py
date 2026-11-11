"""Build a new v4 review from the v3 hat scene; never writes app resources.

Usage: blender --background assets/psilo/review-v3-hat/Psilo-v3-hat.blend \
  --python scripts/build-psilo-review-v4.py -- --out /path/to/new-review
"""
import argparse
import json
import sys
import shutil
from pathlib import Path
import bpy
from mathutils import Vector

parser = argparse.ArgumentParser()
parser.add_argument('--out', required=True)
parser.add_argument('--grain', type=Path)
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
out = Path(args.out).resolve()
if out.exists() and any(out.iterdir()):
    raise ValueError('Choose a new empty review directory; existing work is preserved.')
out.mkdir(parents=True, exist_ok=True)
source = Path(__file__).resolve().parent
scope = {'__name__': 'psilo_review_v4_helpers'}
for name in ['psilo-motion-v2.py', 'psilo-hat-conform-v4.py', 'psilo-surface-v4.py',
             'psilo-reference-markings-v4.py', 'psilo-paper-grain-v4.py']:
    exec(compile((source / name).read_text(), str(source / name), 'exec'), scope)
scene = bpy.context.scene
if 'psilo_hat_v2_location' not in scene.objects['Hat']:
    raise ValueError('Load the v3 fitted-hat scene first.')
scope['restore_psilo_rest'](scene)
geometry = scope['conform_psilo_hat_v4'](scene)
surface = scope['calibrate_psilo_surface_v4'](scene)
markings = scope['fit_reference_spots'](scene)
grain_source = args.grain or source.parent / 'assets/psilo/review-v4-fit-surface/Psilo-paper-grain.png'
shutil.copyfile(grain_source, out / 'Psilo-paper-grain.png')
paper = scope['apply_reference_paper_grain'](scene, str(out / 'Psilo-paper-grain.png'))
scene.render.engine = 'CYCLES'
scene.cycles.device = 'CPU'
scene.cycles.samples = 64
scene.cycles.diffuse_bounces = 2
scene.render.resolution_x, scene.render.resolution_y = 1100, 990
scene.render.resolution_percentage = 100
scene.render.film_transparent = True
scene.render.filepath = '//angle-front.png'
cam = scene.camera
cam.location = (0, -.45, .105)
cam.rotation_euler = (Vector((0, 0, .077)) - cam.location).to_track_quat('-Z', 'Y').to_euler()
cam.data.ortho_scale = .25
cap_image = next(n.image for n in bpy.data.materials['Coral'].node_tree.nodes
                 if n.type == 'TEX_IMAGE' and n.image and 'cap color' in n.image.name)
cap_image.filepath_raw = str(out / 'Psilo-cap-color.png')
cap_image.file_format = 'PNG'
cap_image.save()
cap_image.pack()
cap_image.filepath = '//Psilo-cap-color.png'
for image in bpy.data.images:
    if 'paper-grain' in image.name:
        image.filepath = '//Psilo-paper-grain.png'
bpy.ops.wm.save_as_mainfile(filepath=str(out / 'Psilo-v4.blend'))
scope['animate_psilo'](scene)
scene.frame_set(1)
bpy.ops.wm.save_as_mainfile(filepath=str(out / 'Psilo-v4-motion.blend'))
(out / 'build-manifest.json').write_text(json.dumps({
    'version': 4, 'blender_version': bpy.app.version_string,
    'geometry': geometry, 'surface': surface, 'markings': markings, 'paper': paper,
    'motion_frames': [scene.frame_start, scene.frame_end],
    'status': 'unapproved review only', 'runtime_bake_and_validation_required': True,
}, indent=2) + '\n')
