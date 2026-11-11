"""Reference fidelity refinements on the v5 neutral Blender source.

This is an unapproved review candidate. Cap/hat/face use real 3D meshes;
no camera-facing image plane substitutes for the character.
"""
import bpy
import bmesh
import math
from mathutils import Vector


def smooth(x):
    x=max(0.,min(1.,x))
    return x*x*(3.-2.*x)


def apply_sculpt_v6(scene):
    cap=scene.objects['Cap']
    keys=cap.data.shape_keys.key_blocks
    max_delta=0.
    for key in keys:
        for v in key.data:
            p=v.co.copy();x,y,z=p;h=z+.06
            flank=smooth((h-.038)/.020)*(1.-.7*smooth((h-.09)/.025))
            v.co.x=x*(1.-.075*flank)
            lateral=smooth((abs(x)-.043)/.052)
            back=smooth((y+.045)/.045)
            lower=smooth((.053-h)/.023)
            # Keep the central face edge; let the curled side lip show its
            # substantial dark underside. Right corner hangs slightly lower.
            drop=(.0062+.0010*smooth((x+.01)/.07))*lateral*lower
            v.co.z=z-drop*(.28+.72*back)
            max_delta=max(max_delta,(v.co-p).length)
    # Shift the sculpted mouth recess and the whole face down 3 mm against
    # the final cap, retaining the closed-surface shape used by the smile.
    closed = keys['SmileClose']
    basis = keys['Basis']
    for v, neutral in zip(basis.data, closed.data):
        v.co = neutral.co
        x,y,z = v.co
        distance = (x/.0069)**2 + ((z+.019)/.0049)**2
        if distance < 1 and y < -.035:
            amount = smooth((1-distance)/.55)
            v.co.y += .0046*amount
    for name in ['eye_L','eye_R','mouth_idle','mouth_proud','Glasses','ErrorEyes','ProudEyes']:
        obj = scene.objects.get(name)
        if obj:
            obj.location.z -= .003
            if 'psilo_review_rest_location' in obj:
                obj['psilo_review_rest_location'] = list(obj.location)
    # Match the brim span without reducing its height or changing its tilt.
    scene.view_layers[0].update()
    for name, factor in [('Brim',.90),('Crown',.96),('Band',.96)]:
        obj = scene.objects[name]
        inv = obj.matrix_world.inverted()
        for v in obj.data.vertices:
            world = obj.matrix_world @ v.co
            world.x = -.002 + (world.x+.002)*factor
            v.co = inv @ world
        obj.data.update()
    cap.data.update()
    # Horns are rebuilt as right circular cones by psilo-horn-socket-v6.py
    # after the cap is final. Partial-overlap translations are not attachment.
    # Replace the lower ellipse with a broad, shallow capsule. Top remains
    # buried inside the cap; the visible bottom has a long rounded flat region.
    old=scene.objects['Pedestal'];parent=old.parent;mat=old.data.materials[0]
    profile=[(0.,.0018),(.30,.0018),(.58,.0024),(.79,.0043),
             (.93,.0079),(.995,.013), (1.,.023),(.98,.031),
             (.88,.038),(.60,.043),(0.,.044)]
    points=[(0.,0.,profile[0][1])];faces=[];segments=64
    for r,h in profile[1:-1]:
        for j in range(segments):
            a=j/segments*2*math.pi
            points.append((.050*r*math.cos(a),.036*r*math.sin(a),h))
    points.append((0.,0.,profile[-1][1]));rings=len(profile)-2
    for j in range(segments):faces.append((0,1+(j+1)%segments,1+j))
    for i in range(rings-1):
        for j in range(segments):
            a=1+i*segments+j;b=1+i*segments+(j+1)%segments
            faces.append((a,b,b+segments,a+segments))
    top=len(points)-1
    for j in range(segments):faces.append((1+(rings-1)*segments+j,1+(rings-1)*segments+(j+1)%segments,top))
    mesh=bpy.data.meshes.new('Pedestal_v6_soft_capsule');mesh.from_pydata(points,[],faces);mesh.update()
    bm=bmesh.new();bm.from_mesh(mesh);bmesh.ops.recalc_face_normals(bm,faces=list(bm.faces));bm.to_mesh(mesh);bm.free()
    obj=bpy.data.objects.new('Pedestal_v6_pending',mesh);scene.collection.objects.link(obj);obj.parent=parent
    obj.data.materials.append(mat)
    for p in mesh.polygons:p.use_smooth=True
    sub=obj.modifiers.new('Soft capsule corners','SUBSURF');sub.levels=2;sub.render_levels=2
    oldmesh=old.data;bpy.data.objects.remove(old,do_unlink=True)
    if oldmesh.users==0:bpy.data.meshes.remove(oldmesh)
    obj.name='Pedestal'
    scene.view_layers[0].update()
    # Physical grain coordinates scale by actual mesh dimensions.
    for obj in [cap,scene.objects['Pedestal'],scene.objects['Horn_L'],scene.objects['Horn_R']]:
        bounds=[Vector(p) for p in obj.bound_box]
        obj.color=tuple(max(v[i] for v in bounds)-min(v[i] for v in bounds) for i in range(3))+(1.,)
    return {'version':6,'cap_max_displacement_m':max_delta,
            'horn_attachment':'separate circular-cone helper and full-disc validation',
            'body':'broad capsule with rounded flat bottom',
            'status':'review only; user approval pending'}
