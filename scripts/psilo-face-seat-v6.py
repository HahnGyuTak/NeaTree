"""Seat Psilo's face on the final sculpt; Blender Z-up, front -Y, metres.

Call after final cap geometry and surface-material edits. The eye's existing
Happy shape keys and control names survive. The mouth is the Cap's actual
recessed surface, not an overlaid ellipsoid. An object-space oval mask shades the bowl and
fades with the existing SmileClose key. This is an authoring helper, not a USD
material bake or approval of the new model.
"""
import bpy
import math
from mathutils import Matrix, Vector


def _ray_front(cap, x, z):
    deps = bpy.context.evaluated_depsgraph_get()
    obj = cap.evaluated_get(deps)
    hit, point, normal, index = obj.ray_cast(Vector((x, -.25, z)), Vector((0, 1, 0)))
    if not hit:
        raise ValueError('Final cap does not intersect face ray at %r' % ((x, z),))
    return point, normal.normalized()


def apply_face_seat_v6(scene):
    cap = scene.objects.get('Cap')
    if cap is None or cap.type != 'MESH':
        raise ValueError('Cap mesh is required.')
    capkeys = cap.data.shape_keys
    close = capkeys.key_blocks.get('SmileClose') if capkeys else None
    if close is None:
        raise ValueError('Preserve Cap SmileClose before seating the face.')
    scene.frame_set(1)
    close.value = 0
    scene.view_layers[0].update()
    details = {'eyes': [], 'mouth': 'cap_surface_recess', 'new_protruding_lip': False}
    for side in ('L', 'R'):
        control = scene.objects['eye_' + side]
        bead = scene.objects['EyeDot_' + side]
        parent = control.parent
        # Query in cap coordinates, then convert back into the control parent's.
        old_world = control.matrix_world.translation
        probe = cap.matrix_world.inverted() @ old_world
        point, normal = _ray_front(cap, probe.x, probe.z)
        cap_to_parent = parent.matrix_world.inverted() @ cap.matrix_world
        target = cap_to_parent @ (point + normal * .00010)
        normal = (cap_to_parent.to_3x3() @ normal).normalized()
        inward = -normal
        tangent = inward.cross(Vector((0, 0, 1))).normalized()
        up = tangent.cross(inward).normalized()
        orientation = Matrix((tangent, inward, up)).transposed().to_quaternion()
        control.location = target
        control.rotation_mode = 'QUATERNION'
        control.rotation_quaternion = orientation
        # The same flattened bead moves and morphs; its back is buried 1.05 mm.
        bead.scale.y = .00115
        bead.location = (0, 0, 0)
        keys = bead.data.shape_keys
        if keys and keys.key_blocks.get('Happy'):
            # The old Happy morph pushed the whole lid out of the surface.
            # Keep its existing arch, but seat its flattened depth into the cap.
            for vertex, basis in zip(keys.key_blocks['Happy'].data, keys.key_blocks['Basis'].data):
                vertex.co.y = basis.co.y * .55 + .12
        if 'psilo_review_rest_location' in control:
            control['psilo_review_rest_location'] = list(control.location)
            control['psilo_review_rest_rotation'] = list(orientation)
        details['eyes'].append({'name': control.name, 'local_surface': list(point),
                                'local_center': list(target),
                                'rear_embed_m': .00105, 'front_relief_m': .00125})
    # Current mouth overlays bulge out in front of the sculpted cavity. Hide
    # these source objects rather than deleting named runtime authoring controls.
    for name in ('MouthCavity', 'MouthLowerGlow', 'SmileBacking'):
        obj = scene.objects.get(name)
        if obj:
            obj.hide_render = True
            obj.hide_set(True)
    mesh = cap.data
    # Shade the exact oval in object-space coordinates, avoiding interpolation
    # artifacts from the cap's latitude mesh. The rim stays continuous coral.
    mouth_center = scene.objects['mouth_idle'].matrix_world.translation
    center = cap.matrix_world.inverted() @ mouth_center
    rx, rz = .00585, .0039
    base = bpy.data.materials.get(cap.get('psilo_face_base_material', '')) or cap.data.materials[0]
    cap['psilo_face_base_material'] = base.name
    name = 'Psilo Mouth Surface v6'
    mat = bpy.data.materials.get(name)
    if mat:
        bpy.data.materials.remove(mat, do_unlink=True)
    mat = base.copy()
    mat.name = name
    # All cap polygons use the same paper material, with only this oval mask
    # adding the cavity's pigment. Existing markings/texture stay connected.
    cap.data.materials.clear()
    cap.data.materials.append(mat)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    shader = next(n for n in nodes if n.type == 'BSDF_PRINCIPLED')
    base_socket = shader.inputs['Base Color']
    original = base_socket.links[0].from_socket if base_socket.is_linked else None
    original_color = tuple(base_socket.default_value)
    coordinates = nodes.new('ShaderNodeTexCoord')
    separate = nodes.new('ShaderNodeSeparateXYZ')
    links.new(coordinates.outputs['Object'], separate.inputs['Vector'])
    def mathnode(operation, a, b=None):
        node = nodes.new('ShaderNodeMath')
        node.operation = operation
        if isinstance(a, (float, int)):
            node.inputs[0].default_value = a
        else:
            links.new(a, node.inputs[0])
        if b is not None:
            if isinstance(b, (float, int)):
                node.inputs[1].default_value = b
            else:
                links.new(b, node.inputs[1])
        return node.outputs[0]
    mx = mathnode('DIVIDE', mathnode('SUBTRACT', separate.outputs['X'], center.x), rx)
    mz = mathnode('DIVIDE', mathnode('SUBTRACT', separate.outputs['Z'], center.z), rz)
    # Close the actual dark aperture into a thin oval instead of fading a
    # round red patch. Its material follows the same key as the physical bowl.
    for socket, expression in (
        (mx.node.inputs[1], f'{rx} * (1.0 - 0.35 * close)'),
        (mz.node.inputs[1], f'{rz} * max(0.015, 1.0 - close)'),
    ):
        driver = socket.driver_add('default_value').driver
        driver.expression = expression
        variable = driver.variables.new()
        variable.name = 'close'
        variable.type = 'SINGLE_PROP'
        variable.targets[0].id_type = 'KEY'
        variable.targets[0].id = capkeys
        variable.targets[0].data_path = 'key_blocks["SmileClose"].value'
    r2 = mathnode('ADD', mathnode('MULTIPLY', mx, mx), mathnode('MULTIPLY', mz, mz))
    radius = mathnode('SQRT', r2)
    edge = nodes.new('ShaderNodeMapRange')
    edge.interpolation_type = 'SMOOTHERSTEP'
    edge.clamp = True
    edge.inputs['From Min'].default_value = .985
    edge.inputs['From Max'].default_value = 1.015
    edge.inputs['To Min'].default_value = 1
    edge.inputs['To Max'].default_value = 0
    links.new(radius, edge.inputs['Value'])
    front = mathnode('LESS_THAN', separate.outputs['Y'], -.035)
    lower = nodes.new('ShaderNodeMapRange')
    lower.clamp = True
    lower.inputs['From Min'].default_value = center.z + .0003
    lower.inputs['From Max'].default_value = center.z - .0035
    lower.inputs['To Min'].default_value = 0
    lower.inputs['To Max'].default_value = 1
    links.new(separate.outputs['Z'], lower.inputs['Value'])
    pigment = nodes.new('ShaderNodeMixRGB')
    pigment.name = 'Warm recessed lower inner wall'
    pigment.inputs[1].default_value = (.030, .004, .002, 1)
    pigment.inputs[2].default_value = (.200, .030, .012, 1)
    links.new(lower.outputs['Result'], pigment.inputs[0])
    mask = nodes.new('ShaderNodeMath')
    mask.operation = 'MULTIPLY'
    links.new(mathnode('MULTIPLY', edge.outputs['Result'], front), mask.inputs[0])
    mask.inputs[1].default_value = 1
    driver = mask.inputs[1].driver_add('default_value').driver
    driver.expression = 'min(1.0, max(0.0, (1.0 - close) / 0.12))'
    variable = driver.variables.new()
    variable.name = 'close'
    variable.type = 'SINGLE_PROP'
    variable.targets[0].id_type = 'KEY'
    variable.targets[0].id = capkeys
    variable.targets[0].data_path = 'key_blocks["SmileClose"].value'
    mix = nodes.new('ShaderNodeMixRGB')
    mix.name = 'Inset cavity pigment follows SmileClose'
    if original:
        links.new(original, mix.inputs[1])
    else:
        mix.inputs[1].default_value = original_color
    links.new(pigment.outputs[0], mix.inputs[2])
    links.new(mask.outputs[0], mix.inputs[0])
    links.new(mix.outputs[0], base_socket)
    # Fit the final smile curve to the closed cap instead of pushing it out
    # from behind the face. Its radius will grow uniformly in v6 motion.
    proud = scene.objects.get('mouth_proud')
    smile = scene.objects.get('Smile')
    if proud and smile and smile.type == 'CURVE':
        old_scale = proud.scale.copy()
        proud.scale = (1,1,1)
        close.value = 1
        scene.view_layers[0].update()
        to_cap = cap.matrix_world.inverted() @ smile.matrix_world
        to_smile = smile.matrix_world.inverted() @ cap.matrix_world
        for spline in smile.data.splines:
            for point in spline.bezier_points:
                probe = to_cap @ point.co
                surface, normal = _ray_front(cap, probe.x, probe.z)
                point.co = to_smile @ (surface + normal*.00012)
                point.handle_left_type = 'AUTO'
                point.handle_right_type = 'AUTO'
        smile.data.bevel_depth = 0
        close.value = 0
        proud.scale = old_scale
        details['smile'] = 'seated on closed surface; uniform bevel reveal'
    scene.view_layers[0].update()
    return details
