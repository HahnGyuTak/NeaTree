"""Build isolated v6 review from v5; never replaces app resources."""
import argparse, json, math, sys
from pathlib import Path
import bpy
from mathutils import Vector
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True)
p.add_argument('--draft',action='store_true');p.add_argument('--geometry-only',action='store_true')
a=p.parse_args(sys.argv[sys.argv.index('--')+1:]);out=a.out.resolve()
if out.exists() and any(out.iterdir()):raise ValueError('Use a new empty output directory')
out.mkdir(parents=True,exist_ok=True);scripts=Path(__file__).resolve().parent
scope={'__name__':'psilo_v6_helpers'}
def helper(name):exec(compile((scripts/name).read_text(),str(scripts/name),'exec'),scope)
scene=bpy.context.scene
helper('psilo-motion-v2.py');scope['restore_psilo_rest'](scene)
helper('psilo-sculpt-v6.py');report={'geometry':scope['apply_sculpt_v6'](scene)}
helper('psilo-horn-socket-v6.py')
report['horns']=scope['fit_horn_sockets_v6'](
    scene,surface_anchor=(.057,.026),base_inset=.006,
    base_z=0,virtual_tip_z=.030,base_radius=.014,tip_round_radius=.0008)
if not a.geometry_only:
    helper('psilo-spots-v6.py');report['spots']=scope['apply_spots_v6'](scene)
    helper('psilo-surface-v6.py');report['surface']=scope['apply_surface_v6'](scene, balance_lighting=True)
    helper('psilo-face-seat-v6.py');report['face']=scope['apply_face_seat_v6'](scene)
    helper('psilo-glasses-fit-v6.py');report['glasses']=scope['fit_glasses_v6'](scene)
    helper('psilo-horn-lighting-v6.py');report['horn_lighting']=scope['apply_horn_lighting_v6'](scene)
# Horns grow from the cap; shared motion must not pivot them away from their roots.
horns=scene.objects['Horns'];horns['psilo_attachment']='rigid to Head; only upper-tip deformation allowed'
for image in bpy.data.images:
    if image.name not in ('Render Result','Viewer Node'):
        if not image.packed_file:image.pack()
        if image.filepath:image.filepath='//'+Path(image.filepath).name
scene.render.engine='CYCLES';scene.cycles.device='CPU';scene.cycles.use_denoising=True
scene.cycles.samples=24 if a.draft else 64
scene.render.resolution_x=1000;scene.render.resolution_y=900;scene.render.resolution_percentage=100
scene.render.threads_mode='FIXED';scene.render.threads=6;scene.render.film_transparent=True
cam=scene.camera

def view(angle=0,wide=False):
    r=math.radians(angle);cam.location=(.45*math.sin(r),-.45*math.cos(r),.105)
    cam.rotation_euler=(Vector((0,0,.100 if wide else .077))-cam.location).to_track_quat('-Z','Y').to_euler()
    cam.data.ortho_scale=.34 if wide else .25

def render(name):
    scene.render.filepath=str(out/(name+'.png'));bpy.ops.render.render(write_still=True)
view();scene.render.filepath='//front.png'
bpy.ops.wm.save_as_mainfile(filepath=str(out/'Psilo-v6.blend'))
for name,angle in [('front',0),('left',-35),('right',35)]:
    view(angle);render(name)
    if a.draft:break
if not a.draft:
    scope['animate_psilo'](scene, anchored_horns=True, inset_mouth=True)
    horns.animation_data_clear();horns.rotation_mode='QUATERNION';horns.rotation_quaternion=(1,0,0,0)
    horns.location=Vector(horns['psilo_review_rest_location']);horns.scale=Vector(horns['psilo_review_rest_scale'])
    view(wide=True)
    for name,frame in [('working',88),('proud',141),('error',207),('transition',210)]:
        scene.frame_set(frame);render(name)
    scene.frame_set(1);view();scene.render.filepath='//front.png'
    bpy.ops.wm.save_as_mainfile(filepath=str(out/'Psilo-v6-motion.blend'))
report['production_replaced']=False
(out/'build-manifest.json').write_text(json.dumps(report,indent=2,ensure_ascii=False)+'\n')
print('PSILO_V6 '+json.dumps(report))
