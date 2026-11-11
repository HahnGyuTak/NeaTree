"""Correct how the v2 hat is worn; call after restore_psilo_rest(scene).

The correction is deterministic and keeps the neutral rest transform used by
psilo-motion-v2.py. It changes only the hat assembly; no app resource is exported.
"""
import bpy
from mathutils import Matrix, Quaternion, Vector


def _hat_smooth(value):
    value = max(0.0, min(1.0, value))
    return value * value * (3.0 - 2.0 * value)


def fit_psilo_hat_v3(scene):
    hat, brim = scene.objects['Hat'], scene.objects['Brim']
    if hat.animation_data is not None:
        raise ValueError('Restore the neutral rig before fitting the hat.')
    baseline = 'psilo_hat_v2_positions'
    if baseline not in brim.data:
        brim.data[baseline] = [value for vertex in brim.data.vertices for value in vertex.co]
    coordinates = brim.data[baseline]
    if len(coordinates) != len(brim.data.vertices) * 3:
        raise ValueError('Brim topology differs from the stored v2 baseline.')
    for vertex in brim.data.vertices:
        index = vertex.index * 3
        x, y, z = coordinates[index:index + 3]
        right, front = _hat_smooth((x - .020) / .045), _hat_smooth((-y + .005) / .045)
        vertex.co = (x, y, z + .006 * right * front)
    brim.data.update()
    # The v2 seam extension pokes below the underside once the hat is tilted.
    # Fit its lower ring inside the actual curved brim, closing the joint
    # without leaving the old seam extension visible below the brim.
    crown = scene.objects['Crown']
    if baseline not in crown.data:
        crown.data[baseline] = [value for vertex in crown.data.vertices for value in vertex.co]
    crown_coordinates = crown.data[baseline]
    scene.view_layers[0].update()
    evaluated_brim = brim.evaluated_get(bpy.context.evaluated_depsgraph_get())
    to_brim = brim.matrix_basis.inverted_safe() @ crown.matrix_basis
    to_crown = to_brim.inverted_safe()
    for vertex in crown.data.vertices:
        index = vertex.index * 3
        vertex.co = crown_coordinates[index:index + 3]
        if vertex.index >= len(crown.data.vertices) - 64:
            point = to_brim @ vertex.co
            hit_top, top, _, _ = evaluated_brim.ray_cast(Vector((point.x, point.y, .5)), Vector((0, 0, -1)))
            hit_bottom, bottom, _, _ = evaluated_brim.ray_cast(Vector((point.x, point.y, -.5)), Vector((0, 0, 1)))
            if not (hit_top and hit_bottom):
                raise ValueError('Crown hem falls outside the brim at vertex ' + str(vertex.index))
            point.z = (top.z + bottom.z) * .5
            vertex.co = to_crown @ point
    crown.data.update()
    band = scene.objects['Band']
    if baseline not in band.data:
        band.data[baseline] = [value for vertex in band.data.vertices for value in vertex.co]
    band_coordinates = band.data[baseline]
    origin = Vector((-.002, .003, .047))
    unroll = Matrix.Rotation(.19, 3, 'Y')
    reroll = unroll.transposed()
    for vertex in band.data.vertices:
        index = vertex.index * 3
        original = Vector(band_coordinates[index:index + 3])
        x, y, height = unroll @ (original - origin)
        radius = ((x / .046) ** 2 + (y / .035) ** 2) ** .5
        fitted_height = .008 + .72 * (height - .008)
        fitted_radius = radius + 6.6 * (height - fitted_height)
        factor = fitted_radius / max(radius, .0001)
        vertex.co = origin + reroll @ Vector((x * factor, y * factor, fitted_height))
    band.data.update()
    for field, value in [('location', hat.location), ('rotation', hat.rotation_quaternion)]:
        key = 'psilo_hat_v2_' + field
        if key not in hat:
            hat[key] = list(value)
    base_location = Vector(hat['psilo_hat_v2_location'])
    base_rotation = Quaternion(hat['psilo_hat_v2_rotation'])
    pivot = Vector((-.002, -.003, .048))
    backward = Quaternion((1, 0, 0), -.32)
    hat.rotation_mode = 'QUATERNION'
    hat.rotation_quaternion = backward @ base_rotation
    hat.location = base_location + pivot - backward @ pivot + Vector((0, 0, .001))
    hat['psilo_review_rest_location'] = list(hat.location)
    hat['psilo_review_rest_rotation'] = list(hat.rotation_quaternion)
    hat['psilo_review_rest_scale'] = list(hat.scale)
    hat['psilo_hat_fit_version'] = 'v3-review-unapproved'
    scene.view_layers[0].update()
    return {'pitch_radians': -.32, 'seat_lift_m': .001,
            'right_brim_curl_reduction_m': .006, 'band_width_factor': .72, 'approved': False}
