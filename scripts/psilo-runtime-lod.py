"""Create a separate Blender-only Psilo LOD review artifact, never app assets.

Usage (the neutral source .blend is loaded by Blender first)::

    blender -b assets/psilo/review-v2/Psilo-v2.blend \
      --python scripts/psilo-runtime-lod.py -- /new/path/Psilo-v2-lod.blend

Optional: --triangles 40000 --comparison /new/path/Psilo-v2-lod-studio.blend

The output contains only evaluated Psilo geometry, its named control hierarchy
and existing materials. A separate optional comparison file also has copies of
the original studio objects and render settings for a same-camera comparison.
Neither file is a production USDZ: procedural bump/roughness must still be baked
and validated under RealityKit. This utility never opens or saves the source
file, changes source meshes/materials, renders, or installs an app resource.
"""

import argparse
import json
import math
from pathlib import Path
import sys

import bpy
from mathutils.bvhtree import BVHTree
from mathutils.geometry import barycentric_transform


def triangles(mesh):
    mesh.calc_loop_triangles()
    return len(mesh.loop_triangles)


def capture_shape(scene, obj, key_name):
    """Sample neutral/target with the identical evaluated topology.

    The source key value is restored even if evaluation fails. This deliberately
    requires the neutral authoring scene: an action or driver could override the
    sampled value and silently bake a different expression into the LOD.
    """
    keys = obj.data.shape_keys if obj is not None and obj.type == 'MESH' else None
    if keys is None or keys.key_blocks.get(key_name) is None:
        return None
    if not keys.use_relative:
        raise ValueError(obj.name + '.' + key_name + ' transfer requires relative shape keys.')
    if keys.animation_data and (keys.animation_data.action or keys.animation_data.drivers or keys.animation_data.nla_tracks):
        raise ValueError('Use the neutral source: ' + obj.name + ' shape keys have animation/drivers/NLA.')
    if obj.show_only_shape_key:
        raise ValueError('Disable pinned shape-key display on ' + obj.name + ' before transfer.')
    if any(abs(key.value) > 0.000001 for key in list(keys.key_blocks)[1:]):
        raise ValueError('Use the neutral source: all ' + obj.name + ' shape values must be zero.')
    key = keys.key_blocks[key_name]
    if key.relative_key != keys.reference_key:
        raise ValueError(obj.name + '.' + key_name + ' must be relative to Basis for transfer.')
    saved_value, saved_mute = key.value, key.mute
    samples = []
    try:
        with bpy.context.temp_override(scene=scene, view_layer=scene.view_layers[0]):
            for value in (0.0, 1.0):
                key.mute = False
                key.value = value
                scene.view_layers[0].update()
                deps = bpy.context.evaluated_depsgraph_get()
                mesh = bpy.data.meshes.new_from_object(obj.evaluated_get(deps),
                                                     preserve_all_data_layers=True,
                                                     depsgraph=deps)
                try:
                    mesh.calc_loop_triangles()
                    samples.append((
                        [vertex.co.copy() for vertex in mesh.vertices],
                        [tuple(tri.vertices) for tri in mesh.loop_triangles],
                        [tuple(poly.vertices) for poly in mesh.polygons],
                    ))
                finally:
                    bpy.data.meshes.remove(mesh)
    finally:
        key.value, key.mute = saved_value, saved_mute
        scene.view_layers[0].update()
    neutral, target = samples
    if len(neutral[0]) != len(target[0]) or neutral[2] != target[2]:
        raise ValueError(obj.name + '.' + key_name + ' changes evaluated topology; automatic transfer refused.')
    if not neutral[1]:
        raise ValueError(obj.name + ' has no triangles for shape transfer.')
    return {'neutral': neutral[0], 'target': target[0], 'triangles': neutral[1],
            'polygons': neutral[2], 'key_name': key_name}


def transfer_indexed_shape(obj, sample):
    """Copy exact evaluated deltas for protected, undecimated facial meshes."""
    if sample is None:
        return None
    if (len(obj.data.vertices) != len(sample['neutral'])
            or [tuple(poly.vertices) for poly in obj.data.polygons] != sample['polygons']):
        raise ValueError(obj.name + ' topology changed; direct Happy transfer refused.')
    obj.shape_key_add(name='Basis', from_mix=False)
    key = obj.shape_key_add(name=sample['key_name'], from_mix=False)
    key.value = 0.0
    key.slider_min, key.slider_max = 0.0, 1.0
    max_displacement, max_world_displacement, moved = 0.0, 0.0, 0
    world_linear = obj.matrix_world.to_3x3()
    for vertex, neutral, target in zip(obj.data.vertices, sample['neutral'], sample['target']):
        delta = target - neutral
        key.data[vertex.index].co = vertex.co + delta
        max_displacement = max(max_displacement, delta.length)
        max_world_displacement = max(max_world_displacement, (world_linear @ delta).length)
        moved += delta.length > 0.0000001
    return {'object': obj.name, 'name': sample['key_name'],
            'method': 'exact indexed evaluated displacement; no eye decimation',
            'vertices': len(obj.data.vertices), 'moved_vertices': moved,
            'max_local_displacement_units': max_displacement,
            'max_world_displacement_m': max_world_displacement,
            'runtime_morph_controller_required': True}


def transfer_smile_shape(obj, sample):
    """Transfer evaluated local-space deltas with nearest-triangle barycentrics."""
    if sample is None:
        return None
    neutral, target, faces = sample['neutral'], sample['target'], sample['triangles']
    tree = BVHTree.FromPolygons(neutral, faces, all_triangles=True)
    obj.shape_key_add(name='Basis', from_mix=False)
    smile = obj.shape_key_add(name='SmileClose', from_mix=False)
    smile.value = 0.0
    smile.slider_min, smile.slider_max = 0.0, 1.0
    max_projection_distance = 0.0
    max_world_projection_distance = 0.0
    max_displacement = 0.0
    max_world_displacement = 0.0
    world_linear = obj.matrix_world.to_3x3()
    moved = 0
    for vertex in obj.data.vertices:
        projected, normal, index, distance = tree.find_nearest(vertex.co)
        if index is None:
            raise ValueError('No neutral cap triangle found for a LOD shape vertex.')
        a, b, c = faces[index]
        destination = barycentric_transform(projected, neutral[a], neutral[b], neutral[c],
                                            target[a], target[b], target[c])
        delta = destination - projected
        # Retain the decimated neutral surface; apply only interpolated motion.
        smile.data[vertex.index].co = vertex.co + delta
        max_projection_distance = max(max_projection_distance, distance)
        max_world_projection_distance = max(max_world_projection_distance,
                                            (world_linear @ (vertex.co - projected)).length)
        max_displacement = max(max_displacement, delta.length)
        max_world_displacement = max(max_world_displacement, (world_linear @ delta).length)
        moved += delta.length > 0.0000001
    return {
        'object': obj.name, 'name': 'SmileClose', 'method': 'neutral triangle BVH + barycentric displacement',
        'vertices': len(obj.data.vertices), 'moved_vertices': moved,
        'max_local_projection_distance_units': max_projection_distance,
        'max_world_projection_distance_m': max_world_projection_distance,
        'max_local_displacement_units': max_displacement,
        'max_world_displacement_m': max_world_displacement,
        'runtime_morph_controller_required': True,
    }


def priority(name, count):
    """Face details remain intact; the broad silhouette receives most vertices."""
    facial = ('Eye', 'Mouth', 'Smile', 'Spiral', 'Frame', 'Bridge', 'Arm_')
    if any(token in name for token in facial):
        return count, 0.0
    if name == 'Cap':
        return min(count, 8000), 4.0
    if name.startswith('Horn'):
        return min(count, 1000), 2.3
    if name in ('Brim', 'Crown'):
        return min(count, 1600), 2.2
    if name == 'Band':
        return min(count, 500), 1.2
    if name == 'Pedestal':
        return min(count, 600), 1.0
    return min(count, 200), 0.7


def allocate(meshes, budget):
    counts = {obj.name: triangles(obj.data) for obj in meshes}
    floors = {name: priority(name, count)[0] for name, count in counts.items()}
    if sum(counts.values()) <= budget:
        return counts
    if sum(floors.values()) >= budget:
        # Exceeding the target is preferable to destroying a face or silhouette.
        return floors
    targets = dict(floors)
    left = budget - sum(targets.values())
    active = {name for name in counts if counts[name] > targets[name]}
    while active and left > 0:
        weights = {name: (counts[name] ** 0.65) * priority(name, counts[name])[1]
                   for name in active}
        total = sum(weights.values())
        if total <= 0:
            break
        spent = 0
        for name in active:
            addition = min(counts[name] - targets[name], max(1, int(left * weights[name] / total)))
            targets[name] += addition
            spent += addition
        left -= spent
        active = {name for name in active if targets[name] < counts[name]}
    return targets


def preserve_face(obj, copies):
    """Only vertices outside facial seats may collapse in the cap mesh.

    A zero-weight neighbourhood preserves the inset mouth rim and the surface
    beneath the eye attachments. The modifier's group grants collapse influence
    outside these areas, rather than attempting to repair a cavity afterwards.
    """
    if obj.name != 'Cap':
        return
    mask = obj.vertex_groups.new(name='LOD reducible outside face')
    cap_inv = obj.matrix_world.inverted_safe()
    centres = []
    for name, radius in [('mouth_idle', 0.014), ('eye_L', 0.008), ('eye_R', 0.008)]:
        if name in copies:
            centres.append((cap_inv @ copies[name].matrix_world.translation, radius))
    for vertex in obj.data.vertices:
        influence = 1.0
        for centre, radius in centres:
            distance = (vertex.co - centre).length
            if distance < radius:
                influence = 0.0
                break
            if distance < radius * 1.6:
                influence = min(influence, (distance - radius) / (radius * 0.6))
        mask.add([vertex.index], influence, 'REPLACE')
    return mask.name


def reduce_mesh(obj, target, scene, copies):
    before = triangles(obj.data)
    if before <= target:
        return before, before
    group = preserve_face(obj, copies)
    modifier = obj.modifiers.new('Review LOD decimation', 'DECIMATE')
    modifier.decimate_type = 'COLLAPSE'
    modifier.use_collapse_triangulate = True
    if group:
        modifier.vertex_group = group
        modifier.vertex_group_factor = 1.0
        modifier.invert_vertex_group = False
    ratio = max(0.02, min(1.0, target / before))
    best = None
    best_count = before
    with bpy.context.temp_override(scene=scene, view_layer=scene.view_layers[0]):
        for attempt in range(4):
            modifier.ratio = ratio
            scene.view_layers[0].update()
            deps = bpy.context.evaluated_depsgraph_get()
            mesh = bpy.data.meshes.new_from_object(obj.evaluated_get(deps),
                                                 preserve_all_data_layers=True,
                                                 depsgraph=deps)
            count = triangles(mesh)
            if best is None or abs(count - target) < abs(best_count - target):
                if best is not None:
                    bpy.data.meshes.remove(best)
                best, best_count = mesh, count
            else:
                bpy.data.meshes.remove(mesh)
            if count <= target * 1.04 or ratio <= 0.02:
                break
            ratio = max(0.02, ratio * target / max(count, 1) * 0.95)
    obj.modifiers.remove(modifier)
    old = obj.data
    # Keep Generated-coordinate materials aligned to the authored local bounds.
    best.use_auto_texspace = False
    best.texspace_location = old.texspace_location
    best.texspace_size = old.texspace_size
    obj.data = best
    if old.users == 0:
        bpy.data.meshes.remove(old)
    return before, best_count


def copy_rna_settings(source, dest):
    """Copy simple render settings without linking the original object tree."""
    for prop in source.bl_rna.properties:
        if prop.identifier == 'rna_type' or prop.is_readonly or prop.type in {'POINTER', 'COLLECTION'}:
            continue
        try:
            setattr(dest, prop.identifier, getattr(source, prop.identifier))
        except (AttributeError, TypeError, ValueError):
            pass


def create_lod(source_scene, output, budget=40000, comparison=None):
    output = Path(output).resolve()
    comparison = Path(comparison).resolve() if comparison else None
    source_path = Path(bpy.data.filepath).resolve() if bpy.data.filepath else None
    for path in [output] + ([comparison] if comparison else []):
        if path == source_path or path.exists():
            raise ValueError('Choose a new review artifact path; refusing overwrite: ' + str(path))
        path.parent.mkdir(parents=True, exist_ok=True)
    root = source_scene.objects.get('Psilo')
    if root is None:
        raise ValueError('The loaded scene has no Psilo root.')
    sources = [root] + list(root.children_recursive)
    if any(obj.type not in {'EMPTY', 'MESH', 'CURVE', 'SURFACE', 'FONT'} for obj in sources):
        raise ValueError('Unexpected rig object type; inspect before flattening this hierarchy.')
    for obj in sources:
        animation = obj.animation_data
        if animation and (animation.action or animation.drivers or animation.nla_tracks):
            raise ValueError('Use the neutral source: ' + obj.name + ' has animation/drivers/NLA.')
    names = {obj: obj.name for obj in sources}
    smile_sample = capture_shape(source_scene, source_scene.objects.get('Cap'), 'SmileClose')
    happy_samples = {name: capture_shape(source_scene, source_scene.objects.get(name), 'Happy')
                     for name in ['EyeDot_L', 'EyeDot_R']}
    if any(sample is None for sample in happy_samples.values()):
        raise ValueError('Both EyeDot_L and EyeDot_R require the final Happy shape key before LOD review.')
    viewport_hidden = {obj: obj.hide_get(view_layer=source_scene.view_layers[0]) for obj in sources}
    source_scene.view_layers[0].update()
    with bpy.context.temp_override(scene=source_scene, view_layer=source_scene.view_layers[0]):
        source_deps = bpy.context.evaluated_depsgraph_get()
        world = {obj: obj.evaluated_get(source_deps).matrix_world.copy() for obj in sources}
        geometry = {obj: bpy.data.meshes.new_from_object(obj.evaluated_get(source_deps),
                       preserve_all_data_layers=True, depsgraph=source_deps)
                    for obj in sources if obj.type != 'EMPTY'}
    review_scene = bpy.data.scenes.new('Psilo Runtime LOD Review')
    review_scene.unit_settings.system = 'METRIC'
    review_scene.unit_settings.scale_length = source_scene.unit_settings.scale_length
    copies = {}
    extra_objects = []
    try:
        # Names are global Blender datablocks. Temporarily free them so the saved
        # copy retains the exact names expected by the app rig. Restore in finally.
        for obj, name in names.items():
            obj.name = '__PSILO_LOD_SOURCE__' + name
        for obj in sources:
            new = bpy.data.objects.new(names[obj], geometry.get(obj))
            review_scene.collection.objects.link(new)
            copies[names[obj]] = new
            new.hide_render = obj.hide_render
            new.hide_viewport = obj.hide_viewport
            for key in obj.keys():
                if key.startswith('psilo_review_rest_'):
                    new[key] = obj[key]
        for obj in sources:
            new = copies[names[obj]]
            parent = obj.parent if obj.parent in names else None
            if parent:
                new.parent = copies[names[parent]]
                new.matrix_basis = world[parent].inverted_safe() @ world[obj]
            else:
                new.matrix_basis = world[obj]
        review_scene.view_layers[0].update()
        meshes = [obj for obj in copies.values() if obj.type == 'MESH']
        targets = allocate(meshes, budget)
        records = []
        for obj in meshes:
            before, after = reduce_mesh(obj, targets[obj.name], review_scene, copies)
            records.append({'name': obj.name, 'before': before, 'target': targets[obj.name], 'after': after})
        morph = transfer_smile_shape(copies['Cap'], smile_sample) if 'Cap' in copies else None
        eye_morphs = [transfer_indexed_shape(copies[name], sample)
                      for name, sample in happy_samples.items()]
        # Preserve both global flags and per-view-layer hidden state. In
        # particular, the superseded SmileBacking must remain hidden.
        for original in sources:
            copies[names[original]].hide_set(viewport_hidden[original], view_layer=review_scene.view_layers[0])
        total = sum(record['after'] for record in records)
        material_names = sorted({mat.name for obj in meshes for mat in obj.data.materials if mat})
        report = {
            'purpose': 'Unapproved Blender LOD review; not a production runtime asset',
            'target_triangles': budget, 'actual_triangles': total,
            'original_triangles': sum(record['before'] for record in records),
            'within_ten_percent_of_target': total <= budget * 1.1,
            'mesh_count': len(meshes), 'materials': material_names, 'objects': records,
            'shape_transfer': morph,
            'eye_shape_transfers': eye_morphs,
            'source_frame': source_scene.frame_current,
            'baking_required': True,
            'limitations': [
                'Procedural materials require normal/roughness/color baking for RealityKit.',
                'No visual parity or runtime performance claim follows from triangle count.',
                'Current evaluated pose is preserved; use the neutral source before export.',
                'Close-up facial seats and mouth cavity need multi-angle visual review.',
                'SmileClose and both Happy eye keys are retained; the app morph controller is not implemented here.',
            ],
        }
        review_scene['psilo_lod_review'] = json.dumps(report)
        bpy.data.libraries.write(str(output), {review_scene}, path_remap='RELATIVE_ALL', fake_user=True, compress=True)
        if comparison:
            copy_rna_settings(source_scene.render, review_scene.render)
            copy_rna_settings(source_scene.render.image_settings, review_scene.render.image_settings)
            copy_rna_settings(source_scene.view_settings, review_scene.view_settings)
            copy_rna_settings(source_scene.display_settings, review_scene.display_settings)
            if hasattr(source_scene, 'cycles'):
                copy_rna_settings(source_scene.cycles, review_scene.cycles)
            review_scene.world = source_scene.world
            for obj in source_scene.objects:
                if not obj.name.startswith('STUDIO_'):
                    continue
                clone = obj.copy()
                if obj.data:
                    clone.data = obj.data.copy()
                clone.animation_data_clear()
                clone.parent = None
                clone.matrix_world = obj.matrix_world.copy()
                review_scene.collection.objects.link(clone)
                extra_objects.append(clone)
                if obj == source_scene.camera:
                    review_scene.camera = clone
            bpy.data.libraries.write(str(comparison), {review_scene}, path_remap='RELATIVE_ALL', fake_user=True, compress=True)
        output.with_suffix('.metrics.json').write_text(json.dumps(report, indent=2) + '\n')
        print('PSILO_LOD_REVIEW ' + json.dumps(report))
        return report
    finally:
        for obj in list(copies.values()) + extra_objects:
            data = obj.data
            bpy.data.objects.remove(obj, do_unlink=True)
            if data is not None and data.users == 0 and isinstance(data, bpy.types.Mesh):
                bpy.data.meshes.remove(data)
        bpy.data.scenes.remove(review_scene)
        for obj, name in names.items():
            obj.name = name


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output')
    parser.add_argument('--triangles', type=int, default=40000)
    parser.add_argument('--comparison')
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
    if args.triangles < 10000:
        parser.error('This face-preserving review helper requires at least 10000 triangles.')
    create_lod(bpy.context.scene, args.output, args.triangles, args.comparison)
