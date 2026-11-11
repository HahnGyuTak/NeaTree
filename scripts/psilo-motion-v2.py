"""Editable Blender review animation for Psilo, not a runtime clip replacement.

Call ``animate_psilo(bpy.context.scene)`` after creating the neutral rig. The
scene must use Blender Z-up, front -Y, metres. Only named control transforms are
keyed; meshes, materials, lighting and camera are left untouched. The production
app still needs its continuous, interruptible spring driver. These keyframes are
a visual specification for that driver, not evidence that app playback matches.

The first invocation remembers authored local poses on the controls. Subsequent
calls reuse those poses, so they do not accidentally adopt an animated frame as
the new rest pose. ``restore_psilo_rest(scene)`` removes this helper's animation
and restores the authored neutral pose before a static runtime model export.
"""

import bpy
import math
from mathutils import Euler, Quaternion, Vector


_CONTROL_NAMES = (
    'Psilo', 'Base', 'Head', 'Hat', 'Horns', 'Glasses',
    'eye_L', 'eye_R', 'mouth_idle', 'mouth_proud', 'ErrorEyes', 'ProudEyes',
    'spiral_L', 'spiral_R', 'file_0', 'file_1', 'file_2',
)
_PREFIX = 'psilo_review_rest_'


def _smooth(a, b, t):
    x = max(0.0, min(1.0, (t - a) / max(0.00001, b - a)))
    return x * x * x * (10.0 + x * (-15.0 + 6.0 * x))


def _window(a, b, c, d, t):
    return _smooth(a, b, t) * (1.0 - _smooth(c, d, t))


def _bell(center, width, t):
    return math.exp(-((t - center) / width) ** 2)


def _bezier(a, b, c, d, amount):
    u = 1.0 - amount
    return u ** 3 * a + 3.0 * u * u * amount * b + 3.0 * u * amount ** 2 * c + amount ** 3 * d


def _objects(scene):
    return {name: scene.objects.get(name) for name in _CONTROL_NAMES
            if scene.objects.get(name) is not None}


def _rest(obj):
    if _PREFIX + 'location' not in obj:
        obj[_PREFIX + 'location'] = list(obj.location)
        obj[_PREFIX + 'rotation'] = list(obj.matrix_basis.to_quaternion())
        obj[_PREFIX + 'scale'] = list(obj.scale)
    return (Vector(obj[_PREFIX + 'location']),
            Quaternion(obj[_PREFIX + 'rotation']),
            Vector(obj[_PREFIX + 'scale']))


def restore_psilo_rest(scene):
    """Restore the authored neutral transforms before a static USD export."""
    for obj in _objects(scene).values():
        if _PREFIX + 'location' not in obj:
            continue
        location, rotation, scale = _rest(obj)
        obj.animation_data_clear()
        obj.rotation_mode = 'QUATERNION'
        obj.location, obj.rotation_quaternion, obj.scale = location, rotation, scale
    for name in ['Cap', 'EyeDot_L', 'EyeDot_R']:
        mesh = scene.objects.get(name)
        if mesh and mesh.data.shape_keys:
            mesh.data.shape_keys.animation_data_clear()
            for shape in mesh.data.shape_keys.key_blocks:
                shape.value = 0
    scene.frame_set(1)


def _curves(action):
    # Blender 5 uses layered actions. Legacy actions are supported for reuse.
    seen = set()
    result = []
    for layer in getattr(action, 'layers', ()):
        for strip in layer.strips:
            for bag in getattr(strip, 'channelbags', ()):
                for curve in bag.fcurves:
                    pointer = (curve.data_path, curve.array_index)
                    if pointer not in seen:
                        seen.add(pointer)
                        result.append(curve)
    for curve in getattr(action, 'fcurves', ()):
        if (curve.data_path, curve.array_index) not in seen:
            result.append(curve)
    return result


def animate_psilo(scene, anchored_horns=False, inset_mouth=False):
    """Key a 12-second, 24fps review sequence and return useful still frames.

    At 0–1.6s eyes lead a small curious head turn; 1.6–3s stages attention,
    staggered paper arrival and glasses; 3–4.8s reads the documents; 4.8–6.5s
    celebrates twice; 6.5–7.5s begins another job; 7.6–10s holds the error;
    10–12s visibly regains balance and returns to the neutral pose.
    """
    controls = _objects(scene)
    required = ['Psilo', 'Head', 'Glasses', 'eye_L', 'eye_R', 'mouth_idle',
                'mouth_proud', 'ErrorEyes', 'file_0', 'file_1', 'file_2']
    missing = [name for name in required if name not in controls]
    happy_keys = {}
    for name in ['EyeDot_L', 'EyeDot_R']:
        mesh = scene.objects.get(name)
        keys = mesh.data.shape_keys if mesh and mesh.type == 'MESH' else None
        if keys is None or keys.key_blocks.get('Happy') is None:
            missing.append(name + '.Happy shape key')
        else:
            happy_keys[name] = keys.key_blocks['Happy']
    if missing:
        raise ValueError('Missing Psilo animation controls: ' + ', '.join(missing))
    bases = {name: _rest(obj) for name, obj in controls.items()}
    for obj in controls.values():
        obj.animation_data_clear()
        obj.rotation_mode = 'QUATERNION'
    for shape in happy_keys.values():
        shape.id_data.animation_data_clear()
        shape.value = 0

    def pose(name, offset=(0, 0, 0), angles=(0, 0, 0), scale=(1, 1, 1), logical=False):
        if name not in controls:
            return
        obj = controls[name]
        location, rotation, original_scale = bases[name]
        obj.location = location + Vector(offset)
        obj.rotation_quaternion = rotation @ Euler(angles, 'XYZ').to_quaternion()
        # Accessory controls authored at .001 hide a full-sized local mesh.
        base_scale = Vector((1, 1, 1)) if logical and max(original_scale) < 0.01 else original_scale
        obj.scale = Vector(tuple(max(0.001, base_scale[i] * scale[i]) for i in range(3)))

    def head_angles(t):
        attention = _window(1.45, 1.8, 2.1, 2.6, t)
        read = _window(2.55, 3.0, 4.75, 5.25, t)
        second = _window(6.55, 7.15, 9.95, 10.7, t)
        error = _window(7.55, 7.95, 10.05, 10.85, t)
        pride = _window(4.8, 5.15, 6.05, 6.55, t)
        look = _window(0.65, 1.05, 1.35, 1.9, t)
        scan = math.sin((t - 3.0) * 2.25) * read
        shrug = _bell(5.25, 0.18, t) - 0.8 * _bell(5.85, 0.2, t)
        pitch = -0.07 * attention + 0.09 * (read + second) - 0.055 * pride
        roll = 0.055 * look + 0.06 * shrug + 0.085 * math.sin((t - 7.55) * 5.4) * error
        yaw = 0.10 * look + 0.075 * scan + 0.035 * math.sin(t * 2) * second
        return pitch, roll, yaw

    scene.render.fps = 24
    scene.frame_start, scene.frame_end = 1, 289
    for marker in list(scene.timeline_markers):
        if marker.name.startswith('PSILO '):
            scene.timeline_markers.remove(marker)
    stills = {'idle': 1, 'cursor': 28, 'incoming': 49, 'glasses_landing': 63,
              'file_analysis': 88, 'structure_analysis': 106, 'proud': 127,
              'second_shrug': 141, 'error': 207, 'recovering': 255, 'settled': 289}
    for name, frame in stills.items():
        scene.timeline_markers.new('PSILO ' + name, frame=frame)

    # Eyelid/expression transitions need frame-level samples. Three-frame
    # sampling is sufficient for body motion but can skip a short blink entirely.
    expression_frames = set()
    for start, end in [(0.1, 0.45), (3.95, 4.25), (4.75, 5.2),
                       (6.0, 6.6), (7.5, 8.0), (10.0, 11.25)]:
        expression_frames.update(range(int(start * 24) + 1, int(end * 24) + 2))
    frames = sorted(set(range(1, 290, 3)) | set(stills.values()) | expression_frames | {289})
    for frame in frames:
        t = (frame - 1) / 24.0
        scene.frame_set(frame)
        end_settle = 1.0 - _smooth(11.25, 12.0, t)
        read = _window(2.55, 3.0, 4.75, 5.2, t)
        pride = _window(4.8, 5.15, 6.05, 6.55, t)
        error = _window(7.55, 7.95, 10.05, 10.85, t)
        shrug = _bell(5.25, 0.18, t) + 0.8 * _bell(5.85, 0.2, t)
        compress = 0.025 * _bell(1.7, 0.17, t) + 0.035 * shrug
        breathe = 0.004 * math.sin(t * 1.8) * end_settle
        pose('Psilo', scale=(1, 1, 1 + breathe))
        pose('Base', scale=(1 + compress * 0.4, 1 + compress * 0.4, 1 - compress))
        angles = head_angles(t)
        lift = 0.0012 * math.sin(t * 1.8) * end_settle + 0.0020 * shrug
        pose('Head', offset=(0, 0, lift), angles=angles)
        # Counter-rotation is a small local lag, not an extra whole-head rotation.
        delayed = head_angles(max(0, t - 0.08))
        lag = tuple((delayed[i] - angles[i]) * 0.65 for i in range(3))
        pose('Hat', angles=lag)
        pose('Horns', angles=(0, 0, 0) if anchored_horns else tuple(v * 0.28 for v in lag))

        gaze = _window(0.45, 0.75, 1.4, 1.8, t)
        gaze_x = 0.0012 * gaze + 0.0008 * math.sin((t - 2.9) * 2.25) * read
        gaze_z = 0.0005 * gaze - 0.0007 * read
        blink = 1 - 0.94 * max(_bell(0.28, 0.065, t), _bell(4.1, 0.065, t), _bell(11.1, 0.065, t))
        # Pride morphs each existing eye into its arched eyelid. Neither eye
        # retracts or changes object size during that transition or its recovery.
        # Error alone closes both eyes with identical timing before the spirals.
        error_close = _smooth(0.16, 0.62, error)
        for name in ['eye_L', 'eye_R']:
            pose(name, offset=(gaze_x, 0.012 * _smooth(0.35, 0.9, error_close), gaze_z),
                 scale=(1, 1, max(0.045, blink * (1 - error_close))))
        for shape in happy_keys.values():
            shape.value = pride
            shape.keyframe_insert(data_path='value', frame=frame)
        # The old separate curve eyes stay dormant; the new surface morph owns
        # both neutral and proud expressions, including all intermediate frames.
        pose('ProudEyes', scale=(0.001, 0.001, 0.001), logical=True)
        face_z = (bases['eye_L'][0].z + bases['eye_R'][0].z) * 0.5
        for name, amount in [('ErrorEyes', _smooth(0.36, 0.88, error))]:
            if name not in controls:
                continue
            height = 0.045 + 0.955 * amount
            # These groups are based at Head, so compensate the local face
            # centre when flattening their curves; the eyes must not slide up.
            centre_z = face_z - bases[name][0].z
            pose(name, offset=(0, 0.012 * (1 - amount), centre_z * (1 - height)),
                 scale=(1, 1, height), logical=True)
        for name in ['spiral_L', 'spiral_R']:
            # Rotate about the front-facing local Y axis in Blender space.
            pose(name, angles=(0, (t - 7.55) * 3.0, 0))
        # Keep the dark interior fixed. SmileClose naturally occludes it as the
        # depression closes, avoiding a red empty dent during the reverse motion.
        pose('mouth_idle')
        smile_amount = (_smooth(0.82, 0.995, pride) if inset_mouth
                        else _smooth(0.05, 0.48, pride))
        pose('mouth_proud', offset=(0, 0 if inset_mouth else 0.010 * (1 - smile_amount), 0),
             scale=(1, 1, 1), logical=True)
        if inset_mouth and scene.objects.get('Smile'):
            curve = scene.objects['Smile'].data
            curve.bevel_depth = .00065 * smile_amount
            curve.keyframe_insert(data_path='bevel_depth', frame=frame)

        # Two work entrances demonstrate success -> new work -> persistent error.
        entry = 2.0 if t < 6.5 else 6.65
        leave = 4.95 if t < 6.5 else 10.25
        fall = _smooth(entry, entry + 0.65, t)
        exit_amount = _smooth(leave, leave + 0.65, t)
        visible = _smooth(entry, entry + 0.11, t) * (1 - _smooth(leave + 0.49, leave + 0.65, t))
        # Full-scale spectacles glide downward. Shrink only while entering/leaving
        # the distant end of the short path, never while resting on the face.
        pose('Glasses', offset=(0.004 * (1 - fall) - 0.012 * exit_amount,
                              -0.018 * (1 - fall) - 0.028 * exit_amount,
                              0.038 * (1 - fall) + 0.029 * exit_amount),
             angles=(0.12 * (1 - fall), -0.11 * (1 - fall) + 0.18 * exit_amount, 0),
             scale=(visible, visible, visible), logical=True)

        for i in range(3):
            name = 'file_' + str(i)
            arrive = (1.65 if t < 6.5 else 6.55) + 0.16 * i
            depart = (5.45 if t < 6.5 else 10.55) + 0.1 * i
            u = _smooth(arrive, arrive + 0.88, t)
            out = _smooth(depart, depart + 0.75, t)
            endpoint = bases[name][0]
            side = -1 if endpoint.x < 0 else 1
            origin = endpoint + Vector((side * 0.075, 0.025, 0.13 + 0.012 * i))
            c1 = endpoint + Vector((side * 0.065, -0.012, 0.16))
            c2 = endpoint + Vector((-side * 0.012, -0.014, 0.026))
            path = _bezier(origin, c1, c2, endpoint, u)
            path += Vector((side * 0.07, 0.01, 0.10)) * out
            scale = _smooth(arrive, arrive + 0.14, t) * (1 - _smooth(depart + 0.58, depart + 0.75, t))
            # A barely perceptible damped landing, with no physics simulation.
            settle_t = max(0, t - arrive - 0.8)
            settle = math.sin(settle_t * 25) * math.exp(-settle_t * 12) * 0.001
            settle *= _smooth(arrive + 0.8, arrive + 0.9, t) * (1 - out)
            path.z += settle
            pose(name, offset=path - endpoint,
                 angles=(0.20 * (1 - u), side * 0.35 * (1 - u), side * (0.5 * (1 - u) + 0.2 * out)),
                 scale=(scale, scale, scale), logical=True)

        for obj in controls.values():
            for data_path in ['location', 'rotation_quaternion', 'scale']:
                obj.keyframe_insert(data_path=data_path, frame=frame, group='Psilo review pose')

    for name, obj in controls.items():
        action = obj.animation_data.action if obj.animation_data else None
        if action is None:
            continue
        action.name = 'Psilo review | ' + name
        for curve in _curves(action):
            for key in curve.keyframe_points:
                key.interpolation = 'BEZIER'
                key.handle_left_type = 'AUTO_CLAMPED'
                key.handle_right_type = 'AUTO_CLAMPED'
    cap=scene.objects.get('Cap')
    if cap and cap.data.shape_keys and cap.data.shape_keys.key_blocks.get('SmileClose'):
        shape=cap.data.shape_keys.key_blocks['SmileClose']
        for frame in frames:
            t=(frame-1)/24.0
            shape.value=_window(4.8,5.15,6.05,6.55,t)
            shape.keyframe_insert(data_path='value',frame=frame)
    for name in ['Cap', 'EyeDot_L', 'EyeDot_R']:
        mesh = scene.objects.get(name)
        keys = mesh.data.shape_keys if mesh and mesh.type == 'MESH' else None
        action = keys.animation_data.action if keys and keys.animation_data else None
        if action:
            for curve in _curves(action):
                for key in curve.keyframe_points:
                    key.interpolation = 'BEZIER'
                    key.handle_left_type = 'AUTO_CLAMPED'
                    key.handle_right_type = 'AUTO_CLAMPED'
    scene.frame_set(1)
    return stills
