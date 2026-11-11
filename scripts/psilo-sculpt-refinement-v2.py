"""Reproducible Psilo v2 review refinements, following blender-psilo-v2.py.

Call ``refine_psilo_v2(scene)`` on the base authoring scene. This rebuilds the
cap and final profile horns, then applies the current warm material and mouth
adjustments. No renders, saves, app exports or animation edits are performed.
Repeated calls rebuild from the same dimensions, so the lateral rim treatment
does not accumulate. Existing cap/horn geometry is deliberately replaced; keep
the review source versioned before calling this on manually edited geometry.
"""

import bpy
import bmesh
import math


def _cm(a, b, c, d, t):
    return 0.5 * ((2 * b) + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t * t
                  + (-a + 3 * b - 3 * c + d) * t * t * t)


def _profile(controls, count):
    result = []
    for j in range(count):
        at = j / (count - 1) * (len(controls) - 1)
        index = min(int(at), len(controls) - 2)
        t = at - index
        a, b, c, d = [controls[max(0, min(len(controls) - 1, k))]
                      for k in (index - 1, index, index + 1, index + 2)]
        result.append(tuple(_cm(a[n], b[n], c[n], d[n], t) for n in range(len(a))))
    return result


def _outward_normals(mesh):
    bm = bmesh.new()
    try:
        bm.from_mesh(mesh)
        bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
        bm.to_mesh(mesh)
    finally:
        bm.free()
    mesh.update()


def _remove_object(obj):
    mesh = obj.data if obj.type == 'MESH' else None
    bpy.data.objects.remove(obj, do_unlink=True)
    if mesh is not None and mesh.users == 0:
        bpy.data.meshes.remove(mesh)


def _rebuild_cap(scene, head, coral):
    old = scene.objects.get('Cap')
    controls = [(0, .029), (.35, .028), (.72, .028), (.95, .028),
                (1, .034), (1, .043), (.94, .055), (.78, .077),
                (.56, .100), (.31, .113), (0, .116)]
    profile = list(reversed(_profile(controls, 33)))
    points, faces, uvs = [], [], []
    for radius, height in profile:
        for j in range(64):
            phi = 2 * math.pi * j / 64
            x = .105 * radius * math.cos(phi) + .0015 * math.sin(phi) * radius * radius
            y = -.059 * radius * math.sin(phi)
            z = (height - .06 + .0017 * math.cos(phi + .6) * radius * radius
                 - .0035 * max(0, math.sin(phi)) ** 4 * radius ** 4
                 + .007 * (abs(math.cos(phi)) * radius) ** 4)
            points.append((x, y, z))
    for i in range(32):
        for j in range(64):
            a, b = i * 64 + j, i * 64 + (j + 1) % 64
            faces.append((a, b, b + 64, a + 64))
            uvs.append(((j / 64, i / 32), ((j + 1) / 64, i / 32),
                        ((j + 1) / 64, (i + 1) / 32), (j / 64, (i + 1) / 32)))
    mesh = bpy.data.meshes.new('Cap_clean_quad_surface')
    mesh.from_pydata(points, [], faces)
    mesh.update()
    cap = bpy.data.objects.new('Psilo_refined_cap_pending', mesh)
    scene.collection.objects.link(cap)
    cap.parent = head
    mesh.materials.append(coral)
    uv = mesh.uv_layers.new(name='UVMap')
    for poly, coords in zip(mesh.polygons, uvs):
        poly.use_smooth = True
        for index, coord in zip(poly.loop_indices, coords):
            uv.data[index].uv = coord
    with bpy.context.temp_override(scene=scene, view_layer=scene.view_layers[0],
                                   object=cap, active_object=cap):
        bpy.ops.object.select_all(action='DESELECT')
        cap.select_set(True)
        scene.view_layers[0].objects.active = cap
        sub = cap.modifiers.new('Soft cap', 'SUBSURF')
        sub.levels = 2
        sub.render_levels = 2
        bpy.ops.object.modifier_apply(modifier=sub.name)
    _outward_normals(cap.data)
    closed_surface = [v.co.copy() for v in cap.data.vertices]
    for vertex in cap.data.vertices:
        x, y, z = vertex.co
        distance = (x / .0069) ** 2 + ((z + .016) / .0049) ** 2
        if distance < 1 and y < -.035:
            amount = min(1, max(0, (1 - distance) / .55))
            amount = amount * amount * (3 - 2 * amount)
            vertex.co.y += .0046 * amount
    cap.shape_key_add(name='Basis')
    close = cap.shape_key_add(name='SmileClose')
    for vertex, original in zip(close.data, closed_surface):
        vertex.co = original
    # A single continuous quad surface avoids collapsing boolean mouth faces.
    # Roll the front lateral lip upward, leaving the rear underside in place.
    # The weaker right curl preserves the reference's slight asymmetry.
    def smooth(value):
        value = max(0, min(1, value))
        return value * value * (3 - 2 * value)
    for shape in cap.data.shape_keys.key_blocks:
        for vertex in shape.data:
            x, y, z = vertex.co
            base = z - .007 * (abs(x) / .105) ** 4
            lateral = smooth((abs(x) - .045) / .047)
            front = smooth((-y - .005) / .030)
            rim = smooth((.075 - (base + .06)) / .045)
            amplitude = .0048 + .0027 * smooth((.015 - x) / .03)
            vertex.co.z = base + amplitude * lateral * front * rim
    close.value = 0.0
    # Smooth the expression itself, not only the neutral base surface.
    finish = cap.modifiers.new('Final facial surface', 'SUBSURF')
    finish.levels = 1
    finish.render_levels = 1
    if old:
        _remove_object(old)
    cap.name = 'Cap'
    return cap


def _rebuild_horns(scene, parent, cream):
    # Height, lateral centre and radius fitted to the reference's full cashew.
    controls = [(.069, .074, 0), (.072, .073, .0085), (.079, .071, .016),
                (.089, .073, .020), (.098, .078, .017), (.108, .079, .012),
                (.116, .075, .009), (.121, .073, .005), (.123, .072, 0)]
    profile = _profile(controls, 41)
    result = []
    for sign, label in [(-1, 'L'), (1, 'R')]:
        old = scene.objects.get('Horn_' + label)
        points, faces = [], []
        for z, centre, radius in profile:
            radius = max(0, radius)
            for j in range(48):
                angle = 2 * math.pi * j / 48
                points.append((sign * (centre + radius * math.cos(angle)),
                               -.023 - radius * .9 * math.sin(angle), z - .06))
        for i in range(40):
            for j in range(48):
                a, b = i * 48 + j, i * 48 + (j + 1) % 48
                faces.append((a, b, b + 48, a + 48))
        mesh = bpy.data.meshes.new('Horn_' + label + '_reference_volume')
        mesh.from_pydata(points, [], faces)
        mesh.update()
        obj = bpy.data.objects.new('Psilo_refined_horn_pending_' + label, mesh)
        scene.collection.objects.link(obj)
        obj.parent = parent
        mesh.materials.append(cream)
        for polygon in mesh.polygons:
            polygon.use_smooth = True
        _outward_normals(mesh)
        sub = obj.modifiers.new('Soft closed horn volume', 'SUBSURF')
        sub.levels = 1
        sub.render_levels = 2
        if old:
            _remove_object(old)
        obj.name = 'Horn_' + label
        result.append(obj)
    return result


def _linear(value):
    return value / 12.92 if value < .04045 else ((value + .055) / 1.055) ** 2.4


def _rgb(hex_value):
    return tuple(_linear(int(hex_value[i:i + 2], 16) / 255) for i in (0, 2, 4))


def refine_psilo_v2(scene):
    """Apply the current review refinement deterministically to the base rig."""
    required_objects = ['Head', 'Horns', 'Cap', 'MouthLowerGlow', 'SmileBacking']
    required_materials = ['Coral', 'Cream', 'Hat', 'Sage']
    missing = [name for name in required_objects if scene.objects.get(name) is None]
    missing += [name for name in required_materials if bpy.data.materials.get(name) is None]
    if missing:
        raise ValueError('Run the base Psilo v2 authoring first; missing: ' + ', '.join(missing))
    scene.frame_set(1)
    cap = _rebuild_cap(scene, scene.objects['Head'], bpy.data.materials['Coral'])
    horns = _rebuild_horns(scene, scene.objects['Horns'], bpy.data.materials['Cream'])
    # Keep each eye one continuous volume from bead to pleased closed eyelid.
    for name in ['EyeDot_L', 'EyeDot_R']:
        eye = scene.objects[name]
        if eye.data.shape_keys:
            eye.shape_key_clear()
        basis = eye.shape_key_add(name='Basis')
        happy = eye.shape_key_add(name='Happy')
        happy.value = 0.0
        for vertex, original in zip(happy.data, basis.data):
            x, y, z = original.co
            vertex.co = (x * 1.10, y * .40 - .25, z * .18 + .45 * (1 - x * x))
    pedestal = scene.objects['Pedestal']
    pedestal.location.z = .023
    pedestal.scale.z = .0187
    for name, value in [('Cream', 'FFD495'), ('Hat', 'FFD89F'), ('Sage', '77772E')]:
        material = bpy.data.materials[name]
        shader = next(node for node in material.node_tree.nodes if node.type == 'BSDF_PRINCIPLED')
        color = (*_rgb(value), 1)
        shader.inputs['Base Color'].default_value = color
        material.diffuse_color = color
    for name in required_materials:
        material = bpy.data.materials[name]
        nodes, links = material.node_tree.nodes, material.node_tree.links
        for node in nodes:
            if node.type == 'BUMP':
                node.inputs['Strength'].default_value = .32
                node.inputs['Distance'].default_value = .00032
        if not nodes.get('Psilo paper color grain'):
            shader = next(node for node in nodes if node.type == 'BSDF_PRINCIPLED')
            base = shader.inputs['Base Color']
            source = base.links[0].from_socket if base.is_linked else None
            mix = nodes.new('ShaderNodeMixRGB')
            mix.name = 'Psilo paper color grain'
            mix.blend_type = 'MULTIPLY'
            mix.inputs[0].default_value = 1
            if source:
                links.new(source, mix.inputs[1])
            else:
                mix.inputs[1].default_value = base.default_value
            coordinates = nodes.new('ShaderNodeTexCoord')
            noise = nodes.new('ShaderNodeTexNoise')
            noise.inputs['Scale'].default_value = 420
            noise.inputs['Detail'].default_value = 3
            noise.inputs['Roughness'].default_value = .7
            links.new(coordinates.outputs['Generated'], noise.inputs['Vector'])
            ramp = nodes.new('ShaderNodeValToRGB')
            ramp.color_ramp.elements[0].position = .15
            ramp.color_ramp.elements[0].color = (.86, .86, .86, 1)
            ramp.color_ramp.elements[1].position = .85
            ramp.color_ramp.elements[1].color = (1.06, 1.06, 1.06, 1)
            links.new(noise.outputs['Fac'], ramp.inputs['Fac'])
            links.new(ramp.outputs['Color'], mix.inputs[2])
            links.new(mix.outputs[0], base)
    scene.objects['MouthLowerGlow'].location.y = -.0008
    scene.objects['MouthLowerGlow'].scale.z = .0011
    scene.objects['SmileBacking'].hide_render = True
    scene.objects['SmileBacking'].hide_viewport = True
    scene.view_settings.exposure = .55
    scene.view_layers[0].update()
    return {'cap': cap.name, 'horns': [obj.name for obj in horns],
            'shape_keys': ['Basis', 'SmileClose'], 'production_approved': False}


if __name__ == '__main__':
    print('PSILO_SCULPT_REVIEW ' + str(refine_psilo_v2(bpy.context.scene)))
