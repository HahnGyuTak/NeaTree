"""Fit the hidden upper-left Psilo cap shoulder below the v3 hat.

Call after restore_psilo_rest(scene) on the neutral v3 rig. Geometry only:
materials, lights, cameras, horn meshes and the hat silhouette are untouched.
The same displacement is applied to every cap shape key. The 4mm target
allows for discretization/subdivision and the existing ~2-degree hat lag.
This is an authoring fit, not a runtime collision solver.
"""
import bpy
import math
from mathutils import Vector
from mathutils.bvhtree import BVHTree


def _clearance_smooth(t):
    t = min(1.0, max(0.0, t))
    return t * t * (3.0 - 2.0 * t)


def _clearance_tree(obj, inverse_hat, deps):
    evaluated = obj.evaluated_get(deps)
    mesh = evaluated.to_mesh()
    try:
        transform = inverse_hat @ obj.matrix_world
        vertices = [transform @ v.co for v in mesh.vertices]
        faces = [tuple(poly.vertices) for poly in mesh.polygons]
        return BVHTree.FromPolygons(vertices, faces)
    finally:
        evaluated.to_mesh_clear()


def fit_psilo_hat_clearance_v4(scene, margin=.004, falloff=.024, grid_step=.0015):
    """Fit the left shoulder; extend the smooth join under the central crown.

    Repeated calls undo the stored displacement before recalculating, so a
    caller can refine material/light settings independently without cumulative
    sculpting. Existing authored cap keys retain their exact relative deltas.
    """
    if margin <= 0 or falloff <= 0 or grid_step <= 0:
        raise ValueError("Margin, falloff and grid step must be positive.")
    cap, hat = scene.objects['Cap'], scene.objects['Hat']
    keys = cap.data.shape_keys
    if keys is None:
        raise ValueError('The v3 cap with relative shape keys is required.')
    if keys.animation_data is not None:
        raise ValueError('Restore the neutral rig before applying hat clearance.')
    if any(abs(key.value) > 1e-6 for key in list(keys.key_blocks)[1:]):
        raise ValueError('Cap shape values must be neutral.')
    attribute_name = 'psilo_clearance_v4_delta'
    old_delta = cap.data.attributes.get(attribute_name)
    if old_delta:
        for key in keys.key_blocks:
            for vertex, stored in zip(key.data, old_delta.data):
                vertex.co -= stored.vector
        cap.data.attributes.remove(old_delta)
    scene.view_layers[0].update()
    deps = bpy.context.evaluated_depsgraph_get()
    inverse_hat = hat.matrix_world.inverted_safe()
    cap_to_hat = inverse_hat @ cap.matrix_world
    hat_to_cap = cap_to_hat.inverted_safe()
    cap_tree = _clearance_tree(cap, inverse_hat, deps)
    brim_tree = _clearance_tree(scene.objects['Brim'], inverse_hat, deps)
    crown_tree = _clearance_tree(scene.objects['Crown'], inverse_hat, deps)
    xmin, xmax, ymin, ymax = -.10, .028, -.055, .075
    nx, ny = int(math.ceil((xmax - xmin) / grid_step)) + 1, int(math.ceil((ymax - ymin) / grid_step)) + 1
    values = [0.0] * (nx * ny)
    down, up = Vector((0, 0, -1)), Vector((0, 0, 1))
    constraints = []
    for iy in range(ny):
        y = ymin + iy * grid_step
        for ix in range(nx):
            x = xmin + ix * grid_step
            if x >= 0:
                continue
            top, _, _, _ = cap_tree.ray_cast(Vector((x, y, .5)), down)
            upper, _, _, _ = brim_tree.ray_cast(Vector((x, y, .5)), down)
            lower, _, _, _ = brim_tree.ray_cast(Vector((x, y, -.5)), up)
            if top is None or upper is None or lower is None:
                continue
            crown, _, _, _ = crown_tree.ray_cast(Vector((x, y, .5)), down)
            ceiling = crown.z - margin if crown is not None else lower.z - margin
            amount = max(0.0, top.z - ceiling)
            if amount > .00001:
                constraints.append((ix, iy, amount))
    # Smooth radial envelopes preserve the minimum clearance and extend the
    # fit beyond the literal footprint, so no red ridge appears at its edge.
    radius = int(math.ceil(falloff / grid_step))
    kernel = []
    for oy in range(-radius, radius + 1):
        for ox in range(-radius, radius + 1):
            distance = math.hypot(ox, oy) * grid_step
            if distance < falloff:
                weight = (1.0 - (distance / falloff) ** 2) ** 2
                kernel.append((ox, oy, weight))
    for ix, iy, amount in constraints:
        for ox, oy, weight in kernel:
            xx, yy = ix + ox, iy + oy
            if 0 <= xx < nx and 0 <= yy < ny:
                index = yy * nx + xx
                values[index] = max(values[index], amount * weight)

    def sample(x, y):
        gx, gy = (x - xmin) / grid_step, (y - ymin) / grid_step
        ix, iy = int(math.floor(gx)), int(math.floor(gy))
        if ix < 0 or iy < 0 or ix >= nx - 1 or iy >= ny - 1:
            return 0.0
        tx, ty = gx - ix, gy - iy
        a, b = values[iy * nx + ix], values[iy * nx + ix + 1]
        c, d = values[(iy + 1) * nx + ix], values[(iy + 1) * nx + ix + 1]
        return (a * (1-tx) + b * tx) * (1-ty) + (c * (1-tx) + d * tx) * ty

    deltas = []
    moved = 0
    maximum = 0.0
    for vertex in keys.reference_key.data:
        original = vertex.co.copy()
        p = cap_to_hat @ original
        # A vertical blend wider than 1.5x the deepest correction prevents
        # the shoulder from folding into a ring at the lower cutoff.
        # Front facial vertices lie outside the XY field; the underside
        # and the visible far-right cap remain fixed. The final 24mm
        # blends under the crown, avoiding an artificial central crease.
        high = _clearance_smooth((original.z + .025) / .050)
        left = _clearance_smooth((.024 - original.x) / .024)
        amount = sample(p.x, p.y) * high * left
        p.z -= amount
        delta = hat_to_cap @ p - original if amount > 1e-10 else Vector((0, 0, 0))
        deltas.append(delta)
        maximum = max(maximum, delta.length)
        moved += delta.length > 1e-7
    for key in keys.key_blocks:
        for vertex, delta in zip(key.data, deltas):
            vertex.co += delta
    attribute = cap.data.attributes.new(attribute_name, 'FLOAT_VECTOR', 'POINT')
    for stored, delta in zip(attribute.data, deltas):
        stored.vector = delta
    cap.data.update()
    scene.view_layers[0].update()
    result = {'margin_m': margin, 'falloff_m': falloff, 'grid_step_m': grid_step,
              'grid_constraints': len(constraints), 'moved_control_vertices': moved,
              'max_displacement_m': maximum, 'materials_changed': False,
              'production_approved': False}
    cap['psilo_clearance_v4'] = str(result)
    return result
