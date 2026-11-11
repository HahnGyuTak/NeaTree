"""Refine the existing Psilo paper surfaces against the approved icon artwork.

Apply to the v5 authoring scene, after geometry edits. Leaves geometry, UVs,
camera transforms and rig controls intact. Surface nodes remain attached to the
mesh; procedural grain needs baking before use by the app's USDZ renderer.
"""
import bpy


def apply_surface_v6(scene, underside=True, balance_lighting=False):
    changes = {'production_approved': False, 'geometry_changed': False,
               'reference': 'assets/icons/AppIcon.icon/Assets/Character.png'}
    scene.view_settings.view_transform = 'AgX'
    scene.view_settings.look = 'AgX - Medium High Contrast'
    scene.view_settings.exposure = .40
    scene.view_settings.gamma = 1
    scene.cycles.use_denoising = True
    changes['view'] = {'transform': 'AgX', 'look': 'Medium High Contrast', 'exposure': .40}
    palette_multiplier = {'Coral': (.82, 1.55, 1.55), 'Cream': (.96, .96, 1.45),
                          'Hat': (.96, .96, 1.45), 'BodyCream': (1.03, 1.03, 1.32),
                          'Sage': (1.0, .98, 1.0)}
    for name, tint in palette_multiplier.items():
        material = bpy.data.materials.get(name)
        if material is None:
            continue
        nodes, links = material.node_tree.nodes, material.node_tree.links
        shader = next(n for n in nodes if n.type == 'BSDF_PRINCIPLED')
        shader.inputs['Roughness'].default_value = .82
        shader.inputs['Specular IOR Level'].default_value = .12
        shader.inputs['Subsurface Weight'].default_value = .006
        shader.inputs['Subsurface Scale'].default_value = .001
        ramp = nodes.get('Paper grain contrast')
        if ramp:
            amount = .25 if name == 'Coral' else .28
            ramp.color_ramp.elements[0].color = (1-amount,)*3+(1,)
            ramp.color_ramp.elements[1].color = (1+amount,)*3+(1,)
        for node in nodes:
            if node.type == 'BUMP':
                node.inputs['Strength'].default_value = .12
                node.inputs['Distance'].default_value = .000028
        # Correct material pigment in linear scene space, not a composited
        # render. The material keeps the authored markings and their UVs.
        correction = nodes.get('V6 calibrated paper pigment')
        if correction is None:
            original = shader.inputs['Base Color'].links[0].from_socket
            correction = nodes.new('ShaderNodeMixRGB')
            correction.name = 'V6 calibrated paper pigment'
            correction.blend_type = 'MULTIPLY'
            correction.inputs[0].default_value = 1
            links.new(original, correction.inputs[1])
            links.new(correction.outputs['Color'], shader.inputs['Base Color'])
        correction.inputs[2].default_value = (*tint, 1)
        if name == 'Coral':
            paint = nodes.get('Reference spot artwork in cap coordinates')
            if paint and paint.inputs[0].is_linked:
                selector = nodes.get('V6 pigment swatch selector') or nodes.new('ShaderNodeMixRGB')
                selector.name = 'V6 pigment swatch selector'
                selector.inputs[1].default_value = (*tint, 1)
                selector.inputs[2].default_value = (1.03, 1.02, 1.20, 1)
                links.new(paint.inputs[0].links[0].from_socket, selector.inputs[0])
                links.new(selector.outputs['Color'], correction.inputs[2])
        # Broad, very low contrast pigment variation provides the reference's
        # hand-pressed paper surface without boosting high-frequency speckle.
        if name == 'Coral' and not nodes.get('V6 soft paper pigment variation'):
            coords = nodes.get('Object attached metre coordinates')
            if coords:
                noise = nodes.new('ShaderNodeTexNoise')
                noise.name = 'V6 soft paper pigment variation'
                noise.inputs['Scale'].default_value = 250
                noise.inputs['Detail'].default_value = 2.2
                noise.inputs['Roughness'].default_value = .55
                links.new(coords.outputs['Vector'], noise.inputs['Vector'])
                value = nodes.new('ShaderNodeMapRange')
                value.name = 'V6 subtle pigment range'
                value.inputs['From Min'].default_value = .1
                value.inputs['From Max'].default_value = .9
                value.inputs['To Min'].default_value = .92
                value.inputs['To Max'].default_value = 1.08
                links.new(noise.outputs['Fac'], value.inputs['Value'])
                variation = nodes.new('ShaderNodeMixRGB')
                variation.name = 'V6 physical pigment mottling'
                variation.blend_type = 'MULTIPLY'
                variation.inputs[0].default_value = 1
                links.new(correction.outputs['Color'], variation.inputs[1])
                links.new(value.outputs['Result'], variation.inputs[2])
                links.new(variation.outputs['Color'], shader.inputs['Base Color'])
    # Keep the printed side spots continuous around the curved cheek. The
    # old front-hemisphere hard cut left a straight line in oblique views.
    coral = bpy.data.materials['Coral']
    for node in list(coral.node_tree.nodes):
        if (node.type == 'MATH' and node.operation == 'LESS_THAN'
                and abs(node.inputs[1].default_value + .003) < 1e-6
                and node.inputs[0].is_linked):
            links = coral.node_tree.links
            fade = coral.node_tree.nodes.new('ShaderNodeMapRange')
            fade.name = 'V6 rounded side spot wrap'
            fade.interpolation_type = 'SMOOTHERSTEP'
            fade.clamp = True
            fade.inputs['From Min'].default_value = .005
            fade.inputs['From Max'].default_value = .020
            fade.inputs['To Min'].default_value = 1
            fade.inputs['To Max'].default_value = 0
            links.new(node.inputs[0].links[0].from_socket, fade.inputs['Value'])
            consumers = [link.to_socket for link in node.outputs[0].links]
            for socket in consumers: links.new(fade.outputs['Result'], socket)
    ink = bpy.data.materials.get('Ink')
    if ink:
        ink_shader = next(n for n in ink.node_tree.nodes if n.type == 'BSDF_PRINCIPLED')
        ink_shader.inputs['Roughness'].default_value = .50
        ink_shader.inputs['Specular IOR Level'].default_value = .22
    changes['side_spot_wrap'] = 'smooth continuation around curved cap side'
    changes['ink_roughness'] = .50
    if underside:
        material = bpy.data.materials['Coral']
        nodes, links = material.node_tree.nodes, material.node_tree.links
        shader = next(n for n in nodes if n.type == 'BSDF_PRINCIPLED')
        rusty = nodes.get('V6 underside attached pigment')
        if rusty is None:
            original = shader.inputs['Base Color'].links[0].from_socket
            geometry = nodes.new('ShaderNodeNewGeometry')
            geometry.name = 'V6 surface normal'
            normal = nodes.new('ShaderNodeVectorTransform')
            normal.name = 'V6 object space normal'
            normal.vector_type = 'NORMAL'
            normal.convert_from = 'WORLD'
            normal.convert_to = 'OBJECT'
            links.new(geometry.outputs['Normal'], normal.inputs['Vector'])
            normal_z = nodes.new('ShaderNodeSeparateXYZ')
            links.new(normal.outputs['Vector'], normal_z.inputs['Vector'])
            downward = nodes.new('ShaderNodeMapRange')
            downward.name = 'V6 downward underside falloff'
            downward.interpolation_type = 'SMOOTHERSTEP'
            downward.inputs['From Min'].default_value = -.05
            downward.inputs['From Max'].default_value = -.65
            downward.clamp = True
            links.new(normal_z.outputs['Z'], downward.inputs['Value'])
            coords = nodes.new('ShaderNodeTexCoord')
            position = nodes.new('ShaderNodeSeparateXYZ')
            links.new(coords.outputs['Object'], position.inputs['Vector'])
            lower = nodes.new('ShaderNodeMapRange')
            lower.name = 'V6 underside lower cap region'
            lower.interpolation_type = 'SMOOTHERSTEP'
            lower.inputs['From Min'].default_value = -.008
            lower.inputs['From Max'].default_value = -.025
            lower.clamp = True
            links.new(position.outputs['Z'], lower.inputs['Value'])
            mask = nodes.new('ShaderNodeMath')
            mask.name = 'V6 inner downward surface mask'
            mask.operation = 'MULTIPLY'
            links.new(downward.outputs['Result'], mask.inputs[0])
            links.new(lower.outputs['Result'], mask.inputs[1])
            pigment = nodes.new('ShaderNodeMixRGB')
            pigment.name = 'V6 darker rust underside'
            pigment.blend_type = 'MULTIPLY'
            pigment.inputs[0].default_value = 1
            pigment.inputs[2].default_value = (.36, .36, .34, 1)
            links.new(original, pigment.inputs[1])
            rusty = nodes.new('ShaderNodeMixRGB')
            rusty.name = 'V6 underside attached pigment'
            links.new(mask.outputs[0], rusty.inputs[0])
            links.new(original, rusty.inputs[1])
            links.new(pigment.outputs['Color'], rusty.inputs[2])
            links.new(rusty.outputs['Color'], shader.inputs['Base Color'])
        changes['underside'] = {'mask': 'object normal Z < -0.05 to -0.65, local height -0.008 to -0.025m',
                                'pigment_multiplier': [.36, .36, .34]}
    if balance_lighting:
        energies = {'STUDIO_Key': 1.9, 'STUDIO_Fill': .72, 'STUDIO_Rim': .85, 'STUDIO_LowFill': .30}
        for name, energy in energies.items():
            if scene.objects.get(name):
                scene.objects[name].data.energy = energy
        changes['studio_energy_balance'] = energies
    # Keep softly directional modelling light. Only the old linked body bounce
    # is reduced slightly to retain the warm shadow where cap meets pedestal.
    if scene.objects.get('STUDIO_BodyBounce'):
        scene.objects['STUDIO_BodyBounce'].data.energy = .85
    changes['linear_pigment_multipliers'] = palette_multiplier
    changes['paper_grain_contrast'] = {'cap': .25, 'cream_hat': .28}
    changes['paper_bump_m'] = .000028
    changes['body_bounce_energy'] = .85
    return changes
