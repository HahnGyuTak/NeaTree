"""Right circular cones with a small spherical tip and buried flat base.

Every section perpendicular to the cone axis is circular. Sides are never warped
for attachment. Choose/validate the whole planar base inside the cap separately.
Coordinates use the cap's Blender Z-up basis; Horns stays rigidly on Head.
"""
import bpy,bmesh,math
from mathutils import Vector


def fit_horn_sockets_v6(scene, segments=64, basal_rings=12, side_rings=28,
                        cx=.065, cy=-.012, base_z=-.015, virtual_tip_z=.042,
                        base_radius=.0254, tip_round_radius=.00065,
                        axis=(0, 0, 1), surface_anchor=None, base_inset=.006):
    cap=scene.objects['Cap'];parent=scene.objects['Horns']
    to_parent=parent.matrix_world.inverted()@cap.matrix_world
    slope=base_radius/(virtual_tip_z-base_z)
    angle=math.atan(slope)
    sphere_z=virtual_tip_z-tip_round_radius/math.sin(angle)
    join_z=virtual_tip_z-tip_round_radius*math.cos(angle)**2/math.sin(angle)
    profile=[]
    for i in range(side_rings+1):
        z=base_z+(join_z-base_z)*i/side_rings
        profile.append((z,(virtual_tip_z-z)*slope,False))
    for i in range(1,9):
        theta=(math.pi/2-angle)*(1-i/9)
        profile.append((sphere_z+tip_round_radius*math.cos(theta),tip_round_radius*math.sin(theta),True))
    reports=[]
    for sign,side in [(-1,'L'),(1,'R')]:
        center=Vector((sign*cx,cy,base_z))
        cone_axis=Vector((sign*axis[0],axis[1],axis[2])).normalized()
        placed_center=center.copy();surface=None
        if surface_anchor is not None:
            evaluated_cap=cap.evaluated_get(bpy.context.evaluated_depsgraph_get())
            hit,surface,normal,_=evaluated_cap.ray_cast(
                Vector((sign*surface_anchor[0],-.25,surface_anchor[1])),Vector((0,1,0)))
            if not hit:raise ValueError('Horn anchor does not intersect the cap: '+side)
            cone_axis=normal.normalized()
            placed_center=surface-cone_axis*base_inset
        rotation=Vector((0,0,1)).rotation_difference(cone_axis).to_matrix()
        old=scene.objects['Horn_'+side];mat=old.data.materials[0]
        points=[center.copy()];faces=[];basal=[];ring_ids=[-1]
        for i in range(1,basal_rings+1):
            radius=base_radius*i/basal_rings
            for j in range(segments):
                phi=2*math.pi*j/segments
                points.append(center+Vector((radius*math.cos(phi),radius*math.sin(phi),0)))
                ring_ids.append(-1)
        for j in range(segments):faces.append((0,1+(j+1)%segments,1+j));basal.append(True)
        for i in range(basal_rings-1):
            for j in range(segments):
                a=1+i*segments+j;b=1+i*segments+(j+1)%segments
                faces.append((a,b,b+segments,a+segments));basal.append(True)
        seam=list(range(1+(basal_rings-1)*segments,1+basal_rings*segments))
        for i in seam:ring_ids[i]=0
        previous=seam
        for k,(z,radius,rounded) in enumerate(profile[1:],1):
            ring=[]
            for j in range(segments):
                phi=2*math.pi*j/segments
                ring.append(len(points))
                points.append(Vector((sign*cx+radius*math.cos(phi),cy+radius*math.sin(phi),z)))
                ring_ids.append(k)
            for j in range(segments):
                faces.append((previous[j],previous[(j+1)%segments],ring[(j+1)%segments],ring[j]));basal.append(False)
            previous=ring
        tip=len(points);points.append(Vector((sign*cx,cy,sphere_z+tip_round_radius)));ring_ids.append(len(profile))
        for j in range(segments):faces.append((previous[j],previous[(j+1)%segments],tip));basal.append(False)
        mesh=bpy.data.meshes.new('Horn_'+side+'_vertical_circular_cone')
        cap_points=[placed_center+rotation@(v-center) for v in points]
        mesh.from_pydata([to_parent@v for v in cap_points],[],faces);mesh.update()
        bm=bmesh.new();bm.from_mesh(mesh);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(mesh);bm.free()
        flags=mesh.attributes.new('psilo_basal_face','BOOLEAN','FACE')
        for item,value in zip(flags.data,basal):item.value=value
        flags=mesh.attributes.new('psilo_basal_perimeter','BOOLEAN','POINT')
        for i in seam:flags.data[i].value=True
        rings=mesh.attributes.new('psilo_circle_ring','INT','POINT')
        for item,value in zip(rings.data,ring_ids):item.value=value
        obj=bpy.data.objects.new('Horn_'+side+'_pending',mesh);scene.collection.objects.link(obj);obj.parent=parent;mesh.materials.append(mat)
        normal_matrix=to_parent.to_3x3().inverted().transposed();normals=[]
        for polygon in mesh.polygons:
            polygon.use_smooth=True
            for loop in polygon.loop_indices:
                p=points[mesh.loops[loop].vertex_index]
                if basal[polygon.index]:n=Vector((0,0,-1))
                elif p.z>=join_z-1e-8:
                    n=(p-Vector((sign*cx,cy,sphere_z))).normalized()
                else:
                    radial=Vector((p.x-sign*cx,p.y-cy,0)).normalized()
                    n=radial*math.cos(angle)+Vector((0,0,math.sin(angle)))
                normals.append(tuple((normal_matrix@rotation@n).normalized()))
        mesh.normals_split_custom_set(normals)
        obj['psilo_horn_design']='right circular cone, rounded tip, fully buried planar base'
        obj['psilo_axis']='cone longitudinal axis; circular perpendicular sections'
        obj['psilo_cone_axis_cap']=list(cone_axis)
        obj['psilo_cone_base_center_cap']=list(placed_center)
        if surface is not None:
            obj['psilo_surface_anchor_cap']=list(surface)
            obj['psilo_base_inset_m']=base_inset
        obj['psilo_basal_mode']='entire planar disc must be inside cap'
        obj['psilo_center_xy']=list(placed_center[:2])
        obj['psilo_base_z']=placed_center.z;obj['psilo_base_radius']=base_radius
        obj['psilo_tip_round_radius']=tip_round_radius
        oldmesh=old.data;bpy.data.objects.remove(old,do_unlink=True)
        if oldmesh.users==0:bpy.data.meshes.remove(oldmesh)
        obj.name='Horn_'+side
        scene.view_layers[0].update();bounds=[Vector(p) for p in obj.bound_box]
        obj.color=tuple(max(p[i] for p in bounds)-min(p[i] for p in bounds) for i in range(3))+(1,)
        reports.append({'horn':obj.name,'axis_cap':list(cone_axis),'perpendicular_sections':'circles',
                        'base_center_cap':list(placed_center),'base_radius_m':base_radius,
                        'surface_anchor_cap':list(surface) if surface is not None else None,
                        'base_inset_m':base_inset if surface is not None else None,
                        'virtual_height_m':virtual_tip_z-base_z,
                        'actual_rounded_tip_cap':list(placed_center+cone_axis*(sphere_z+tip_round_radius-base_z)),
                        'tip_round_radius_m':tip_round_radius,'cone_half_angle_degrees':math.degrees(angle),
                        'attachment':'full basal-disc containment must be validated'})
    return {'horns':reports,'cap_geometry_changed':False,'axial_sections_circular':True}
