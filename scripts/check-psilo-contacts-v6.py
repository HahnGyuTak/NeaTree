"""Measure Psilo's sculpt contacts in an already loaded Blender scene.

blender -b candidate.blend --python scripts/check-psilo-contacts-v6.py -- \
  --output /tmp/contacts.json --frames 1,31,67,88,122,141,183,207,210,241,265,289

No model, material, rig or animation edits are made. The scene frame is restored.
Nearest-face signed distance is a local contact approximation for this smooth,
closed cap, not a general boolean-solid test. Eye rear embedding is expected;
metrics and actual multi-angle renders must both be reviewed. Horns require
100% sampled basal face/perimeter contact, or the explicitly tagged full planar-disc
burial mode. Partial intersection never passes either mode.
"""
import argparse
import bpy
import json
import math
import sys
from pathlib import Path
from mathutils import Vector
from mathutils.bvhtree import BVHTree


def _geometry(obj, deps):
    evaluated = obj.evaluated_get(deps)
    mesh = evaluated.to_mesh()
    vertices = [evaluated.matrix_world @ vertex.co for vertex in mesh.vertices]
    polygons = [tuple(poly.vertices) for poly in mesh.polygons]
    evaluated.to_mesh_clear()
    return vertices, polygons


def _signed(bvh, point):
    near, normal, index, distance = bvh.find_nearest(point)
    return float((point - near).dot(normal))


def _round(v):
    return round(float(v), 9)


def _sample_mesh(bvh, obj, deps):
    vertices, _ = _geometry(obj, deps)
    distances = [_signed(bvh, point) for point in vertices]
    return {'vertices': len(vertices),
            'inside_fraction': _round(sum(value < -.00002 for value in distances) / len(distances)),
            'deepest_overlap_m': _round(max(0, -min(distances))),
            'closest_signed_m': _round(min(distances)),
            'maximum_relief_m': _round(max(distances))}


def _horn_basal_surface(bvh, obj, deps, tolerance_m=.00015):
    """Require an entire conforming basal surface, not any partial overlap.

    The horn author must label basal polygons with a FACE-domain Boolean/int
    attribute named psilo_basal_face. Subdivision must retain that label. The
    perimeter is derived from the tagged surface itself, so a detached or open
    edge cannot be omitted by marking only convenient perimeter vertices.
    """
    evaluated = obj.evaluated_get(deps)
    mesh = evaluated.to_mesh()
    try:
        attr = mesh.attributes.get('psilo_basal_face')
        if attr is None or attr.domain != 'FACE':
            return {'full_basal_contact': False,
                    'reason': 'Missing FACE-domain psilo_basal_face annotation; overlap is not a substitute.',
                    'tolerance_m': tolerance_m}
        polygons = [p for p in mesh.polygons if float(attr.data[p.index].value) > .5]
        if not polygons:
            return {'full_basal_contact': False, 'reason': 'No basal polygons are tagged.',
                    'tolerance_m': tolerance_m}
        points = [evaluated.matrix_world @ vertex.co for vertex in mesh.vertices]
        basal_indices = {poly.index for poly in polygons}
        vertex_indices = {index for poly in polygons for index in poly.vertices}
        samples = [points[index] for index in vertex_indices]
        edge_uses = {}
        for poly in polygons:
            for a, b in poly.edge_keys:
                key = tuple(sorted((a, b)))
                edge_uses[key] = edge_uses.get(key, 0) + 1
        boundary = [edge for edge, uses in edge_uses.items() if uses == 1]
        graph = {}
        for a, b in boundary:
            graph.setdefault(a, set()).add(b)
            graph.setdefault(b, set()).add(a)
        loops = 0
        seen = set()
        for start in graph:
            if start in seen:
                continue
            loops += 1
            todo = [start]
            while todo:
                vertex = todo.pop()
                if vertex in seen:
                    continue
                seen.add(vertex)
                todo.extend(graph[vertex] - seen)
        closed_perimeter = bool(graph) and loops == 1 and all(len(neighbours) == 2 for neighbours in graph.values())
        boundary_points = [points[index] for index in graph]
        boundary_points += [(points[a] + points[b]) * .5 for a, b in boundary]
        mesh.calc_loop_triangles()
        normal_dots = []
        degenerate = 0
        for tri in mesh.loop_triangles:
            if tri.polygon_index not in basal_indices:
                continue
            a, b, c = [points[index] for index in tri.vertices]
            normal = (b-a).cross(c-a)
            if normal.length < 1e-12:
                degenerate += 1
                continue
            centre = (a + b + c) / 3
            cap_normal = bvh.find_nearest(centre)[1]
            normal_dots.append(normal.normalized().dot(cap_normal))
            # Vertices alone cannot prove a curved footprint is covered: a
            # flat fan might touch at its rim while the whole middle floats.
            samples.extend([centre, (a+b)*.5, (b+c)*.5, (c+a)*.5,
                            a*.6+b*.2+c*.2, a*.2+b*.6+c*.2, a*.2+b*.2+c*.6])
        distances = [_signed(bvh, point) for point in samples]
        seam = [_signed(bvh, point) for point in boundary_points]
        coverage = sum(abs(d) <= tolerance_m for d in distances) / len(distances)
        seam_coverage = (sum(abs(d) <= tolerance_m for d in seam) / len(seam)) if seam else 0
        opposed = (sum(dot <= -.5 for dot in normal_dots) / len(normal_dots)) if normal_dots else 0
        passed = coverage == 1 and seam_coverage == 1 and closed_perimeter and opposed == 1 and degenerate == 0
        worst = sorted(zip(distances, samples), key=lambda item: abs(item[0]), reverse=True)[:5]
        return {'basal_polygons': len(polygons), 'basal_vertices': len(vertex_indices),
                'surface_samples': len(samples), 'perimeter_samples': len(seam),
                'tolerance_m': tolerance_m,
                'full_surface_coverage_fraction': _round(coverage),
                'full_perimeter_coverage_fraction': _round(seam_coverage),
                'max_surface_gap_m': _round(max(0, max(distances))),
                'max_surface_penetration_m': _round(max(0, -min(distances))),
                'max_absolute_surface_error_m': _round(max(abs(d) for d in distances)),
                'max_absolute_perimeter_error_m': _round(max((abs(d) for d in seam), default=0)),
                'perimeter_closed_single_loop': closed_perimeter,
                'perimeter_loop_count': loops,
                'opposed_normal_fraction': _round(opposed),
                'degenerate_basal_triangles': degenerate,
                'full_basal_contact': passed,
                'largest_errors': [{'signed_distance_m': _round(distance),
                                    'world_point': [_round(x) for x in point]} for distance, point in worst]}
    finally:
        evaluated.to_mesh_clear()


def _buried_disc_and_circles(bvh, obj, deps, cap):
    """Validate the user-authorized complete planar-disc burial alternative."""
    evaluated = obj.evaluated_get(deps)
    mesh = evaluated.to_mesh()
    try:
        flags = mesh.attributes.get('psilo_basal_face')
        rings = mesh.attributes.get('psilo_circle_ring')
        if flags is None or flags.domain != 'FACE' or rings is None or rings.domain != 'POINT':
            return {'attachment_mode': 'fully buried planar disc', 'attachment_valid': False,
                    'reason': 'Basal face and circular-ring annotations are required.'}
        world = [evaluated.matrix_world @ vertex.co for vertex in mesh.vertices]
        axis_cap = Vector(obj.get('psilo_cone_axis_cap', (0, 0, 1)))
        if axis_cap.length < 1e-10:
            return {'attachment_mode': 'fully buried planar disc', 'attachment_valid': False,
                    'reason': 'The declared cone axis is zero.'}
        axis_cap.normalize()
        center_xy = obj.get('psilo_center_xy', (0, 0))
        center_cap = Vector(obj.get('psilo_cone_base_center_cap',
                                    (center_xy[0], center_xy[1], obj.get('psilo_base_z', 0))))
        cap_matrix = cap.evaluated_get(deps).matrix_world
        origin = cap_matrix @ center_cap
        axis = (cap_matrix.to_3x3() @ axis_cap).normalized()
        guide = Vector((1, 0, 0)) if abs(axis.x) < .9 else Vector((0, 1, 0))
        transverse_x = (guide - axis * guide.dot(axis)).normalized()
        transverse_y = axis.cross(transverse_x).normalized()
        surface_point, surface_normal, _, surface_exit = bvh.ray_cast(origin, axis)
        alignment_degrees = (math.degrees(math.acos(max(-1, min(1, axis.dot(surface_normal)))))
                             if surface_normal is not None else None)
        # Measure actual evaluated world geometry in an orthonormal cone frame.
        # This supports a rigid tilt, while catching an elliptical section caused
        # by deformation or nonuniform object/parent scaling.
        local = [Vector(((p-origin).dot(transverse_x), (p-origin).dot(transverse_y),
                         (p-origin).dot(axis))) for p in world]
        polys = [p for p in mesh.polygons if flags.data[p.index].value]
        indices = {p.index for p in polys}
        vertices = {i for p in polys for i in p.vertices}
        if not vertices:
            return {'attachment_mode': 'fully buried planar disc', 'attachment_valid': False,
                    'reason': 'No complete basal disc is tagged.'}
        zspread = max(local[i].z for i in vertices) - min(local[i].z for i in vertices)
        samples = [world[i] for i in vertices]
        mesh.calc_loop_triangles()
        for triangle in mesh.loop_triangles:
            if triangle.polygon_index not in indices:
                continue
            a,b,c = [world[i] for i in triangle.vertices]
            samples.extend([(a+b+c)/3, (a+b)*.5, (b+c)*.5, (c+a)*.5,
                            a*.6+b*.2+c*.2, a*.2+b*.6+c*.2, a*.2+b*.2+c*.6])
        up = (cap_matrix.to_3x3() @ Vector((0,0,1))).normalized()
        depths, upper, lower = [], [], []
        failures = []
        for point in samples:
            depth = -_signed(bvh,point)
            top = bvh.ray_cast(point+up*.25,-up)[0]
            bottom = bvh.ray_cast(top-up*.00001,-up)[0] if top is not None else None
            top_clearance = (top-point).dot(up) if top is not None else -1
            bottom_clearance = (point-bottom).dot(up) if bottom is not None else -1
            depths.append(depth);upper.append(top_clearance);lower.append(bottom_clearance)
            if min(depth,top_clearance,bottom_clearance) <= .000001 and len(failures)<8:
                failures.append({'world_point':list(point),'nearest_depth_m':depth,
                                 'top_clearance_m':top_clearance,'bottom_clearance_m':bottom_clearance})
        inside = sum(min(a,b,c)>.000001 for a,b,c in zip(depths,upper,lower))
        grouped = {}
        for index,item in enumerate(rings.data):
            if item.value >= 0:
                grouped.setdefault(item.value,[]).append(local[index])
        sections=[]
        for ring_id,points in sorted(grouped.items()):
            centre=sum(points,Vector())/len(points)
            radii=[math.hypot(p.x-centre.x,p.y-centre.y) for p in points]
            radius=sum(radii)/len(radii)
            sections.append({'ring':ring_id,'samples':len(points),'center':list(centre),
                             'radius_m':radius,'max_radius_error_m':max(abs(r-radius) for r in radii),
                             'horizontal_z_spread_m':max(p.z for p in points)-min(p.z for p in points)})
        ref=sections[0]['center'] if sections else (0,0,0)
        drift=max((math.hypot(r['center'][0]-ref[0],r['center'][1]-ref[1]) for r in sections),default=1)
        radial_error=max((r['max_radius_error_m'] for r in sections),default=1)
        level_error=max((r['horizontal_z_spread_m'] for r in sections),default=1)
        circular=bool(sections) and drift<1e-6 and radial_error<1e-6 and level_error<1e-6
        straight=[];slope=None
        if len(sections)>2:
            a,b=sections[:2]
            slope=(a['radius_m']-b['radius_m'])/(b['center'][2]-a['center'][2])
            for section in sections:
                expected=a['radius_m']-slope*(section['center'][2]-a['center'][2])
                if abs(section['radius_m']-expected)>1e-6:
                    break
                straight.append(section['ring'])
        contains = inside == len(samples) and zspread<1e-6
        valid = contains and circular and len(straight)>=3
        return {'attachment_mode':'fully buried planar disc', 'attachment_valid':valid,
                'full_basal_containment':contains,'basal_polygons':len(polys),'basal_vertices':len(vertices),
                'disc_samples':len(samples),'inside_samples':inside,'entire_disc_inside_fraction':inside/len(samples),
                'planar_base_axial_spread_m':zspread,'minimum_nearest_surface_depth_m':min(depths),
                'minimum_upper_clearance_m':min(upper),'minimum_lower_clearance_m':min(lower),
                'sections_perpendicular_to_axis_circular':circular,
                'horizontal_sections_circular':circular if abs(axis_cap.z) > 1-1e-6 else None,
                'cone_axis_cap':list(axis_cap),'cone_axis_world':list(axis),
                'cone_base_center_cap':list(center_cap),'circular_ring_count':len(sections),
                'base_normal_to_root_cap_normal_degrees':alignment_degrees,
                'root_center_surface_point_world':list(surface_point) if surface_point is not None else None,
                'root_center_surface_normal_world':list(surface_normal) if surface_normal is not None else None,
                'root_center_axis_surface_exit_m':surface_exit,
                'max_radial_error_m':radial_error,'max_section_axial_spread_m':level_error,
                'max_axis_center_drift_m':drift,'straight_conical_prefix_rings':straight,
                'cone_slope':slope,'rounded_tip_radius_m':obj.get('psilo_tip_round_radius'),
                'rings':sections,'failures':failures,
                'scope':'All marked basal mesh vertices and triangle interiors/edges sampled; sections perpendicular to the declared cone axis are checked in orthonormal world coordinates. Circular rings are polygonal approximations with equal radii, not ellipses.'}
    finally:
        evaluated.to_mesh_clear()


def check_psilo_contacts(scene, frames=(1, 31, 67, 88, 122, 141, 183, 207, 210, 241, 265, 289),
                         glasses_frames=(88, 106, 207, 210), basal_tolerance_m=.00015):
    original = scene.frame_current
    result = {'method': 'evaluated world-space meshes; nearest-face signed distance',
              'units': 'metres', 'frames': [], 'passed': True}
    cap = scene.objects.get('Cap')
    if cap is None:
        raise ValueError('Cap mesh is required.')
    try:
        for frame in frames:
            scene.frame_set(frame)
            deps = bpy.context.evaluated_depsgraph_get()
            vertices, polygons = _geometry(cap, deps)
            bvh = BVHTree.FromPolygons(vertices, polygons)
            item = {'frame': frame, 'horns': {}, 'eyes': {}, 'glasses_front': {}, 'visible_mouth_overlays': []}
            for name in ('Horn_L', 'Horn_R'):
                obj = scene.objects.get(name)
                if obj is None:
                    raise ValueError('Missing ' + name)
                record = (_buried_disc_and_circles(bvh, obj, deps, cap)
                          if obj.get('psilo_basal_mode') == 'entire planar disc must be inside cap'
                          else _horn_basal_surface(bvh, obj, deps, basal_tolerance_m))
                item['horns'][name] = record
                if not record.get('attachment_valid',record.get('full_basal_contact',False)):
                    result['passed'] = False
            for name in ('EyeDot_L', 'EyeDot_R'):
                obj = scene.objects.get(name)
                if obj is None or obj.hide_render:
                    continue
                record = _sample_mesh(bvh, obj, deps)
                # Hidden/retracted error eyes can be fully buried. Their lower
                # overlap is not a fault. Visible neutral eyes need real seating.
                record['seated'] = record['inside_fraction'] >= .06
                item['eyes'][name] = record
                if not record['seated']:
                    result['passed'] = False
            # Settled work/error poses only: entering/leaving glasses follow
            # a separate path and are not required to sit at their rest clearance.
            if frame in glasses_frames:
                for name in ('Frame_L', 'Frame_R', 'Bridge'):
                    obj = scene.objects.get(name)
                    if obj is None:
                        raise ValueError('Missing front spectacles curve ' + name)
                    record = _sample_mesh(bvh, obj, deps)
                    record['entire_front_curve_outside_cap'] = record['closest_signed_m'] >= 0
                    item['glasses_front'][name] = record
                    if not record['entire_front_curve_outside_cap']:
                        result['passed'] = False
            for name in ('MouthCavity', 'MouthLowerGlow', 'SmileBacking'):
                obj = scene.objects.get(name)
                if obj and not obj.hide_render:
                    item['visible_mouth_overlays'].append(name)
            item['mouth_is_shaded_cap_recess'] = any(
                mat and mat.name.startswith('Psilo Mouth Surface v6') for mat in cap.data.materials)
            result['frames'].append(item)
    finally:
        scene.frame_set(original)
    result['visual_review_required'] = ['horn appears attached in side/rear views; entire base must match its declared flush or buried mode',
                                        'mouth interior reads inset, not a front disk',
                                        'eye highlights and embedding remain consistent throughout motion',
                                        'complete spectacles rings are visible in settled work and error views']
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--frames', default='1,31,67,88,122,141,183,207,210,241,265,289')
    args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
    report = check_psilo_contacts(bpy.context.scene, tuple(int(f) for f in args.frames.split(',')))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('PSILO_CONTACTS ' + json.dumps({'passed': report['passed'], 'frames': len(report['frames'])}))
