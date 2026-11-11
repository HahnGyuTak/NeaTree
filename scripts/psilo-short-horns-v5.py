"""Approved short, softly pointed Psilo horns, authored as closed Blender meshes.

Only Horn_L/Horn_R are replaced. Their named parent control and all other
geometry, materials, animation and rig transforms remain intact. Coordinates
are native Blender Z-up, front -Y, metres. The centreline is straight; no hooked
or elbow-shaped portion is present. Call while the scene is in its neutral pose.
"""
import bpy
import bmesh
import math
from mathutils import Vector


def _horn_profile(controls, count):
    """Cubic interpolation retains the rounded root and softly tapered apex."""
    values = []
    for sample in range(count):
        at = sample / (count - 1) * (len(controls) - 1)
        i = min(int(at), len(controls) - 2)
        t = at - i
        a, b, c, d = [controls[max(0, min(len(controls) - 1, j))]
                      for j in (i - 1, i, i + 1, i + 2)]
        values.append(tuple(.5 * ((2 * b[k]) + (-a[k] + c[k]) * t
            + (2 * a[k] - 5 * b[k] + 4 * c[k] - d[k]) * t * t
            + (-a[k] + 3 * b[k] - 3 * c[k] + d[k]) * t * t * t)
                            for k in range(2)))
    return values


def apply_psilo_short_horns_v5(scene, segments=32, rings=25, subdivision=1, front_offset=-.023):
    parent = scene.objects.get('Horns')
    if parent is None:
        raise ValueError('The named Horns rig control is required.')
    # Total length 32mm, width about 30mm: roughly one-third shorter than
    # the prior straight-horn concept, with the approved plump proportion.
    controls = [(0, 0), (.002, .0085), (.006, .0135), (.012, .0148),
                (.019, .0124), (.026, .0076), (.031, .0036),
                (.03365, .0012), (.034, 0)]
    profile = _horn_profile(controls, rings)
    profile = [(height * (.032 / .034), radius) for height, radius in profile]
    lean = math.radians(8)
    results = []
    for sign, side in [(-1, 'L'), (1, 'R')]:
        name = 'Horn_' + side
        old = scene.objects.get(name)
        material = old.data.materials[0] if old and old.data.materials else bpy.data.materials['Cream']
        anchor = Vector((sign * .074, front_offset, .069 - .060))
        axis = Vector((sign * math.sin(lean), 0, math.cos(lean)))
        lateral = Vector((math.cos(lean), 0, -sign * math.sin(lean)))
        depth = Vector((0, 1, 0))
        points = [tuple(anchor)]
        # Single poles, rather than zero-radius rings, avoid degenerate faces.
        for height, radius in profile[1:-1]:
            for j in range(segments):
                angle = 2 * math.pi * j / segments
                p = (anchor + axis * height + lateral * (max(0, radius) * math.cos(angle))
                     + depth * (max(0, radius) * .84 * math.sin(angle)))
                points.append(tuple(p))
        points.append(tuple(anchor + axis * .032))
        faces = []
        ring_count = rings - 2
        for j in range(segments):
            faces.append((0, 1 + (j + 1) % segments, 1 + j))
        for i in range(ring_count - 1):
            for j in range(segments):
                a = 1 + i * segments + j
                b = 1 + i * segments + (j + 1) % segments
                faces.append((a, b, b + segments, a + segments))
        top = len(points) - 1
        for j in range(segments):
            faces.append((1 + (ring_count - 1) * segments + j,
                          1 + (ring_count - 1) * segments + (j + 1) % segments, top))
        mesh = bpy.data.meshes.new(name + '_approved_short_ogive')
        mesh.from_pydata(points, [], faces)
        mesh.update()
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        bm.to_mesh(mesh)
        closed = all(edge.is_manifold for edge in bm.edges)
        bm.free()
        if not closed:
            raise ValueError('Horn mesh must be closed and manifold.')
        obj = bpy.data.objects.new(name + '_replacement', mesh)
        scene.collection.objects.link(obj)
        obj.parent = parent
        mesh.materials.append(material)
        for face in mesh.polygons:
            face.use_smooth = True
        if subdivision:
            modifier = obj.modifiers.new('Soft horn finish', 'SUBSURF')
            modifier.levels = subdivision
            modifier.render_levels = subdivision
        # V4 uses this per-object size metadata for attached physical grain.
        scene.view_layers[0].update()
        bounds = [Vector(c) for c in obj.bound_box]
        obj.color = tuple(max(p[i] for p in bounds) - min(p[i] for p in bounds)
                          for i in range(3)) + (1,)
        if old:
            old_mesh = old.data
            bpy.data.objects.remove(old, do_unlink=True)
            if old_mesh.users == 0:
                bpy.data.meshes.remove(old_mesh)
        obj.name = name
        obj['psilo_horn_design'] = 'approved-short-soft-point-v5'
        results.append({'name': name, 'closed_manifold': closed,
                        'control_vertices': len(mesh.vertices),
                        'axis_length_m': .032, 'outward_lean_degrees': 8,
                        'front_offset_m': front_offset})
    scene.view_layers[0].update()
    return {'horns': results, 'other_geometry_changed': False,
            'shape_approved': True, 'whole_model_approval_implied': False}
