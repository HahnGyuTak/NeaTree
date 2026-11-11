"""Render the loaded review .blend; outputs stay beside that file.

Modes: angles, poses, motion, all. Studio-only; never exports app resources.
"""
import bpy
import sys
import math
from pathlib import Path
from mathutils import Vector

out = Path(bpy.data.filepath).parent
scene = next((s for s in bpy.data.scenes if s.camera and s.objects.get('Psilo')), bpy.context.scene)
if bpy.context.window:
    bpy.context.window.scene = scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 48
scene.cycles.device = 'CPU'
scene.render.resolution_x = 1100
scene.render.resolution_y = 990
scene.render.resolution_percentage = 100
scene.render.image_settings.color_mode = 'RGBA'
scene.render.film_transparent = True
cam = scene.camera
mode = sys.argv[-1]

def aim(angle=0, wide=False):
    rad = math.radians(angle)
    cam.location = (.45 * math.sin(rad), -.45 * math.cos(rad), .105)
    target = Vector((0, 0, .100 if wide else .077))
    cam.rotation_euler = (target - cam.location).to_track_quat('-Z', 'Y').to_euler()
    cam.data.ortho_scale = .36 if wide else .25

if mode in ('angles', 'all'):
    scene.frame_set(1)
    for name, angle in [('front', 0), ('left', -30), ('right', 30), ('side', 65)]:
        aim(angle)
        scene.render.filepath = str(out / ('angle-' + name + '.png'))
        bpy.ops.render.render(write_still=True)
if mode in ('poses', 'all'):
    aim(wide=True)
    for name, frame in [('working', 88), ('proud', 141), ('error', 207), ('recovery', 255)]:
        scene.frame_set(frame)
        scene.render.filepath = str(out / ('pose-' + name + '.png'))
        bpy.ops.render.render(write_still=True)
if mode in ('motion', 'all'):
    aim(wide=True)
    scene.render.engine = 'BLENDER_EEVEE'
    scene.render.resolution_x = 960
    scene.render.resolution_y = 864
    scene.render.film_transparent = False
    scene.render.image_settings.color_mode = 'RGB'
    scene.render.filepath = str(out / 'frames/frame-')
    scene.render.fps = 24
    scene.frame_start = 1
    scene.frame_end = 289
    bpy.ops.render.render(animation=True)
