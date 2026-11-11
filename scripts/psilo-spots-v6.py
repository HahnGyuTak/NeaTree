"""Surface-local Psilo markings, with finite depth instead of an extruded decal.

Call after sculpting the neutral Cap and before surface/face helpers. Keeps the
approved front-projected oval centres, radii and rotations. A smoothly bounded
fourth-power depth term around the actual cap tangent plane prevents the same
oval extending through the cap and reappearing on the back/side silhouette.
The pigment lives in cap coordinates, not screen/world space. Bake for USDZ.
"""
import bpy
import math
from mathutils import Vector


def apply_spots_v6(scene):
    cap = scene.objects['Cap']
    scene.view_layers[0].update()
    evaluated = cap.evaluated_get(bpy.context.evaluated_depsgraph_get())
    material = bpy.data.materials['Coral']
    nodes, links = material.node_tree.nodes, material.node_tree.links
    paint = nodes.get('Reference spot artwork in cap coordinates')
    if paint is None:
        raise ValueError('The existing cap pigment swatches are required.')
    for node in list(nodes):
        if node.name.startswith('V6 spot volume '):
            nodes.remove(node)
    def node(kind, label):
        result = nodes.new(kind)
        result.name = 'V6 spot volume ' + label
        return result
    coord = node('ShaderNodeTexCoord', 'attached coordinates')
    separate = node('ShaderNodeSeparateXYZ', 'local axes')
    links.new(coord.outputs['Object'], separate.inputs['Vector'])
    serial = [0]
    def mathnode(operation, a, b):
        serial[0] += 1
        n = node('ShaderNodeMath', f'{operation} {serial[0]}')
        n.operation = operation
        for index, value in enumerate((a, b)):
            if isinstance(value, (int, float)):
                n.inputs[index].default_value = value
            else:
                links.new(value, n.inputs[index])
        return n.outputs[0]
    merged = 0.
    report = []
    patches = [(-.077, -.006, .0145, .0108, .39),
               (.024, .032, .020, .0123, -.34),
               (.079, -.009, .0138, .0101, -.55)]
    for index, (cx, cz, rx, rz, angle) in enumerate(patches):
        hit, center, normal, _ = evaluated.ray_cast(Vector((cx, -.25, cz)), Vector((0, 1, 0)))
        if not hit:
            raise ValueError(f'Spot {index} misses the sculpted cap.')
        normal.normalize()
        dx = mathnode('SUBTRACT', separate.outputs['X'], center.x)
        dy = mathnode('SUBTRACT', separate.outputs['Y'], center.y)
        dz = mathnode('SUBTRACT', separate.outputs['Z'], center.z)
        u = mathnode('DIVIDE', mathnode('ADD', mathnode('MULTIPLY', dx, math.cos(angle)),
                     mathnode('MULTIPLY', dz, math.sin(angle))), rx)
        v = mathnode('DIVIDE', mathnode('SUBTRACT', mathnode('MULTIPLY', dz, math.cos(angle)),
                     mathnode('MULTIPLY', dx, math.sin(angle))), rz)
        oval = mathnode('ADD', mathnode('MULTIPLY', u, u), mathnode('MULTIPLY', v, v))
        residual = mathnode('ADD', mathnode('ADD', mathnode('MULTIPLY', dx, normal.x),
                            mathnode('MULTIPLY', dy, normal.y)), mathnode('MULTIPLY', dz, normal.z))
        depth = mathnode('DIVIDE', residual, .012)
        depth_square = mathnode('MULTIPLY', depth, depth)
        distance = mathnode('ADD', oval, mathnode('MULTIPLY', depth_square, depth_square))
        edge = node('ShaderNodeMapRange', f'{index} rounded pigment edge')
        edge.interpolation_type = 'SMOOTHERSTEP'
        edge.clamp = True
        edge.inputs['From Min'].default_value = 1.015
        edge.inputs['From Max'].default_value = .985
        links.new(distance, edge.inputs['Value'])
        merged = mathnode('MAXIMUM', merged, edge.outputs['Result'])
        report.append({'center_local': list(center), 'normal_local': list(normal),
                       'projected_radii_m': [rx, rz], 'angle_radians': angle,
                       'normal_depth_m': .012, 'depth_exponent': 4})
    links.new(merged, paint.inputs[0])
    return {'kind': 'finite 3D tangent patch with front oval preservation',
            'patches': report, 'hard_y_clip': False,
            'production_bake_required': True}
