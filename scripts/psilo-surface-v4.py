"""Calibrated matte paper/clay surfaces for the unapproved Psilo v4 review.

Run on a neutral Psilo authoring scene. Physical grain coordinates belong to
each object and follow its rig; no world-space texture projection is used.
These procedural surfaces need baking before a production RealityKit export.
"""

import bpy
from mathutils import Vector


def _surface_rgb(value):
    channels = [int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(x / 12.92 if x <= .04045 else ((x + .055) / 1.055) ** 2.4
                 for x in channels) + (1,)


def calibrate_psilo_surface_v4(scene, cream='FFBF4A', hat='FFC953',
                               sage='585426', fill=.4, grain=1.2):
    image = None
    for node in bpy.data.materials['Coral'].node_tree.nodes:
        if node.type == 'TEX_IMAGE' and node.image:
            image = node.image
            break
    if image is None:
        raise ValueError('Coral requires the authored cap/spot color image')

    # Generated coordinates are normalized per mesh. Multiplying by authored
    # local size makes the grain equally sized on the large cap and small horn.
    # Object color is metadata here, not a display/albedo color.
    for obj in scene.objects:
        if obj.type != 'MESH':
            continue
        bounds = [Vector(corner) for corner in obj.bound_box]
        size = [(max(p[i] for p in bounds) - min(p[i] for p in bounds))
                * abs(obj.scale[i]) for i in range(3)]
        obj.color = (*size, 1)

    for name, color in [('Coral', None), ('Cream', cream), ('Hat', hat), ('Sage', sage)]:
        mat = bpy.data.materials[name]
        mat.use_nodes = True
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        nodes.clear()
        output = nodes.new('ShaderNodeOutputMaterial')
        shader = nodes.new('ShaderNodeBsdfPrincipled')
        shader.inputs['Roughness'].default_value = .83
        shader.inputs['Specular IOR Level'].default_value = .10
        shader.inputs['Subsurface Weight'].default_value = .015
        links.new(shader.outputs['BSDF'], output.inputs['Surface'])

        coords = nodes.new('ShaderNodeTexCoord')
        metadata = nodes.new('ShaderNodeObjectInfo')
        physical = nodes.new('ShaderNodeVectorMath')
        physical.operation = 'MULTIPLY'
        physical.name = 'Object attached metre coordinates'
        links.new(coords.outputs['Generated'], physical.inputs[0])
        links.new(metadata.outputs['Color'], physical.inputs[1])
        fibre = nodes.new('ShaderNodeVectorMath')
        fibre.operation = 'MULTIPLY'
        fibre.inputs[1].default_value = (1, 1, 2.2)
        links.new(physical.outputs['Vector'], fibre.inputs[0])
        noise = nodes.new('ShaderNodeTexNoise')
        noise.name = 'Paper fibre grain'
        noise.inputs['Scale'].default_value = 2800
        noise.inputs['Detail'].default_value = 2.5
        noise.inputs['Roughness'].default_value = .72
        links.new(fibre.outputs['Vector'], noise.inputs['Vector'])
        ramp = nodes.new('ShaderNodeValToRGB')
        ramp.name = 'Paper grain contrast'
        amount = (.365 if name == 'Coral' else .54) * grain
        ramp.color_ramp.elements[0].position = .22
        ramp.color_ramp.elements[0].color = (1 - amount,) * 3 + (1,)
        ramp.color_ramp.elements[1].position = .78
        ramp.color_ramp.elements[1].color = (1 + amount,) * 3 + (1,)
        links.new(noise.outputs['Fac'], ramp.inputs['Fac'])
        mix = nodes.new('ShaderNodeMixRGB')
        mix.name = 'Psilo paper color grain'
        mix.blend_type = 'MULTIPLY'
        mix.inputs[0].default_value = 1
        if name == 'Coral':
            texture = nodes.new('ShaderNodeTexImage')
            texture.image = image
            texture.interpolation = 'Cubic'
            separate = nodes.new('ShaderNodeSeparateColor')
            links.new(texture.outputs['Color'], separate.inputs['Color'])
            difference = nodes.new('ShaderNodeMath')
            difference.operation = 'SUBTRACT'
            links.new(separate.outputs['Red'], difference.inputs[0])
            links.new(separate.outputs['Green'], difference.inputs[1])
            mask = nodes.new('ShaderNodeMapRange')
            mask.inputs['From Min'].default_value = .25
            mask.inputs['From Max'].default_value = .45
            links.new(difference.outputs[0], mask.inputs['Value'])
            pigment = nodes.new('ShaderNodeMixRGB')
            pigment.inputs[1].default_value = (1.27, .99, .61, 1)
            pigment.inputs[2].default_value = (1, .79, .66, 1)
            links.new(mask.outputs['Result'], pigment.inputs[0])
            tint = nodes.new('ShaderNodeMixRGB')
            tint.blend_type = 'MULTIPLY'
            tint.inputs[0].default_value = 1
            links.new(texture.outputs['Color'], tint.inputs[1])
            links.new(pigment.outputs['Color'], tint.inputs[2])
            links.new(tint.outputs['Color'], mix.inputs[1])
        else:
            value = list(_surface_rgb(color))
            if name in ['Cream', 'Hat']:
                value[0] *= 1.20 if name == 'Cream' else 1.25
            mix.inputs[1].default_value = value
            mat.diffuse_color = _surface_rgb(color)
        links.new(ramp.outputs['Color'], mix.inputs[2])
        links.new(mix.outputs['Color'], shader.inputs['Base Color'])
        bump = nodes.new('ShaderNodeBump')
        bump.inputs['Strength'].default_value = .22
        bump.inputs['Distance'].default_value = .00010
        links.new(noise.outputs['Fac'], bump.inputs['Height'])
        links.new(bump.outputs['Normal'], shader.inputs['Normal'])

    body_material = bpy.data.materials.get('BodyCream')
    if body_material:
        bpy.data.materials.remove(body_material, do_unlink=True)
    body_material = bpy.data.materials['Cream'].copy()
    body_material.name = 'BodyCream'
    body_color = list(_surface_rgb('FFCF6D'))
    body_color[0] *= 1.35
    body_material.node_tree.nodes['Psilo paper color grain'].inputs[1].default_value = body_color
    pedestal = scene.objects['Pedestal']
    pedestal.data.materials.clear()
    pedestal.data.materials.append(body_material)

    name = 'STUDIO_LowFill'
    light = scene.objects.get(name)
    if light is None:
        data = bpy.data.lights.new(name, 'AREA')
        light = bpy.data.objects.new(name, data)
        scene.collection.objects.link(light)
    light.location = (0, -.23, -.035)
    light.rotation_euler = (Vector((0, 0, .025)) - light.location).to_track_quat('-Z', 'Y').to_euler()
    light.data.shape = 'DISK'
    light.data.size = .30
    light.data.color = (1, 1, 1)
    light.data.energy = fill

    # The reference includes a soft bounce under the very broad cap. Limit this
    # studio fill to the pedestal so the coral front does not wash out to pink.
    body_fill = scene.objects.get('STUDIO_BodyBounce')
    if body_fill is None:
        data = bpy.data.lights.new('STUDIO_BodyBounce', 'AREA')
        body_fill = bpy.data.objects.new('STUDIO_BodyBounce', data)
        scene.collection.objects.link(body_fill)
    body_fill.location = (0, -.23, -.035)
    body_fill.rotation_euler = light.rotation_euler
    body_fill.data.shape = 'DISK'
    body_fill.data.size = .30
    body_fill.data.color = (1, 1, 1)
    body_fill.data.energy = 1.0
    receivers = bpy.data.collections.get('Psilo body bounce receivers')
    if receivers is None:
        receivers = bpy.data.collections.new('Psilo body bounce receivers')
    pedestal = scene.objects['Pedestal']
    if pedestal.name not in receivers.objects:
        receivers.objects.link(pedestal)
    body_fill.light_linking.receiver_collection = receivers

    ink = bpy.data.materials['Ink']
    ink_shader = next(n for n in ink.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
    ink_shader.inputs['Base Color'].default_value = _surface_rgb('1C1B19')
    interior = bpy.data.materials['Interior']
    interior_shader = next(n for n in interior.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
    interior_shader.inputs['Base Color'].default_value = _surface_rgb('803628')
    return {'palette_srgb': {'cream': cream, 'hat': hat, 'sage': sage},
            'lower_fill': fill, 'grain_multiplier': grain,
            'production_approved': False}
