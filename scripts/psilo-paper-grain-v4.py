"""Reference-derived microscopic paper grain on actual Psilo 3D surfaces.

The tiny seamless bitmap contains grayscale high-pass surface structure only,
from a clean region of the user's Psilo reference; no character image, pigment,
face or lighting is projected onto the model. Bake the BOX maps to UV for app
export. Call after calibrate_psilo_surface_v4 on a neutral authoring scene.
"""
import bpy


def apply_reference_paper_grain(scene, tile_path, cream_reduction=.85):
    tile = bpy.data.images.load(str(tile_path), check_existing=True)
    tile.colorspace_settings.name = 'Non-Color'
    tile.pack()
    tile_world_width = scene.objects['Cap'].dimensions.x * 256 / 1195 * .85
    for name in ('Coral', 'Cream', 'Hat', 'Sage', 'BodyCream'):
        material = bpy.data.materials[name]
        nodes, links = material.node_tree.nodes, material.node_tree.links
        coords = nodes['Object attached metre coordinates']
        repeat_name = 'Paper grain physical repeat'
        repeat = nodes.get(repeat_name) or nodes.new('ShaderNodeVectorMath')
        repeat.name = repeat_name
        repeat.operation = 'SCALE'
        repeat.inputs['Scale'].default_value = 1 / tile_world_width
        links.new(coords.outputs['Vector'], repeat.inputs[0])
        texture_name = 'Reference paper fibre on 3D surface'
        texture = nodes.get(texture_name) or nodes.new('ShaderNodeTexImage')
        texture.name = texture_name
        texture.image = tile
        texture.projection = 'BOX'
        texture.projection_blend = .12
        texture.extension = 'REPEAT'
        texture.interpolation = 'Linear'
        links.new(repeat.outputs['Vector'], texture.inputs['Vector'])
        ramp = nodes['Paper grain contrast']
        amount = .3504 if name == 'Coral' else .6156
        if name in ('Cream', 'BodyCream'):
            amount *= cream_reduction
        ramp.color_ramp.elements[0].color = (1 - amount,) * 3 + (1,)
        ramp.color_ramp.elements[1].color = (1 + amount,) * 3 + (1,)
        links.new(texture.outputs['Color'], ramp.inputs['Fac'])
        bump = next(n for n in nodes if n.type == 'BUMP')
        links.new(texture.outputs['Color'], bump.inputs['Height'])
        bump.inputs['Strength'].default_value = .14
        bump.inputs['Distance'].default_value = .000035
    return {'texture': 'Psilo-paper-grain.png', 'tile_world_width_m': tile_world_width,
            'mapping': 'object attached physical BOX',
            'cream_reduction': cream_reduction, 'production_approved': False}
