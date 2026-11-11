"""Conform the v3 hat opening around the original convex Psilo cap.

Authoring helper; call on the neutral rig. Unlike the earlier cap clearance
experiment this restores any stored clearance displacement and preserves all
cap keys. Only Brim/Crown/Band mesh geometry is fitted; no material is touched.
"""
import bpy
import math
from mathutils import Vector
from mathutils.bvhtree import BVHTree


def _conform_smooth(value):
    x = min(1., max(0., value))
    return x*x*(3-2*x)


def _conform_tree(obj, to_hat, deps):
    ev = obj.evaluated_get(deps)
    mesh = ev.to_mesh()
    try:
        transform = to_hat @ obj.matrix_world
        return BVHTree.FromPolygons([transform @ v.co for v in mesh.vertices],
                                   [tuple(p.vertices) for p in mesh.polygons])
    finally:
        ev.to_mesh_clear()


def conform_psilo_hat_v4(scene, margin=.004, falloff=.040, grid_step=.0015):
    if margin <= 0 or falloff <= 0 or grid_step <= 0:
        raise ValueError('Margin, falloff and grid step must be positive.')
    cap, hat = scene.objects['Cap'], scene.objects['Hat']
    if cap.data.shape_keys.animation_data or hat.animation_data:
        raise ValueError('Restore the neutral Psilo rig before fitting the hat.')
    old = cap.data.attributes.get('psilo_clearance_v4_delta')
    restored_prior_fit = old is not None
    if old:
        for key in cap.data.shape_keys.key_blocks:
            for vertex, stored in zip(key.data, old.data):
                vertex.co -= stored.vector
        cap.data.attributes.remove(old)
        cap.data.update()
    baseline = 'psilo_hat_conform_v4_positions'
    for name in ('Brim', 'Crown', 'Band'):
        obj = scene.objects[name]
        if baseline not in obj.data:
            obj.data[baseline] = [n for v in obj.data.vertices for n in v.co]
        coordinates = obj.data[baseline]
        if len(coordinates) != 3*len(obj.data.vertices):
            raise ValueError('Hat topology changed after conform baseline was stored.')
        for vertex in obj.data.vertices:
            vertex.co = coordinates[vertex.index*3:vertex.index*3+3]
        obj.data.update()
    scene.view_layers[0].update()
    deps = bpy.context.evaluated_depsgraph_get()
    inv = hat.matrix_world.inverted_safe()
    cap_tree = _conform_tree(cap, inv, deps)
    brim_tree = _conform_tree(scene.objects['Brim'], inv, deps)
    crown_tree = _conform_tree(scene.objects['Crown'], inv, deps)
    xmin,xmax,ymin,ymax = -.11,.045,-.075,.09
    nx,ny = math.ceil((xmax-xmin)/grid_step)+1,math.ceil((ymax-ymin)/grid_step)+1
    values = [0.]*(nx*ny)
    down,up = Vector((0,0,-1)),Vector((0,0,1))
    constraints=[]
    for iy in range(ny):
        y=ymin+iy*grid_step
        for ix in range(nx):
            x=xmin+ix*grid_step
            if x>=0:continue
            top,_,_,_=cap_tree.ray_cast(Vector((x,y,.5)),down)
            brim_top,_,_,_=brim_tree.ray_cast(Vector((x,y,.5)),down)
            crown,_,_,_=crown_tree.ray_cast(Vector((x,y,.5)),down)
            if top is None or brim_top is None or crown is not None:continue
            amount=max(0.,top.z+margin-brim_top.z)
            if amount>.00001:constraints.append((ix,iy,amount))
    radius=math.ceil(falloff/grid_step)
    kernel=[(ox,oy,(1-(math.hypot(ox,oy)*grid_step/falloff)**2)**2)
            for oy in range(-radius,radius+1) for ox in range(-radius,radius+1)
            if math.hypot(ox,oy)*grid_step<falloff]
    for ix,iy,amount in constraints:
        for ox,oy,weight in kernel:
            xx,yy=ix+ox,iy+oy
            if 0<=xx<nx and 0<=yy<ny:
                i=yy*nx+xx
                values[i]=max(values[i],amount*weight)
    def sample(x,y):
        gx,gy=(x-xmin)/grid_step,(y-ymin)/grid_step
        ix,iy=math.floor(gx),math.floor(gy)
        if ix<0 or iy<0 or ix>=nx-1 or iy>=ny-1:return 0.
        tx,ty=gx-ix,gy-iy
        a,b=values[iy*nx+ix],values[iy*nx+ix+1]
        c,d=values[(iy+1)*nx+ix],values[(iy+1)*nx+ix+1]
        return (a*(1-tx)+b*tx)*(1-ty)+(c*(1-tx)+d*tx)*ty
    stats={}
    for name in ('Brim','Crown','Band'):
        obj=scene.objects[name]
        to_hat=inv@obj.matrix_world
        back=to_hat.inverted_safe()
        maximum=0.;count=0;frontmax=0.
        for vertex in obj.data.vertices:
            original=vertex.co.copy();p=to_hat@original
            # Brim thickness translates intact. Crown and band bend together,
            # tapering over a height longer than the maximum raising distance.
            vertical=1. if name=='Brim' else 1-_conform_smooth((p.z-.055)/.055)
            front = _conform_smooth(((obj.matrix_world @ original).y + .040) / .030)
            amount=sample(p.x,p.y)*vertical*front
            if amount<1e-10:continue
            p.z+=amount;vertex.co=back@p
            delta=(vertex.co-original).length
            maximum=max(maximum,delta);count+=1
            if (obj.matrix_world@original).y<-.030:frontmax=max(frontmax,delta)
        obj.data.update()
        stats[name]={'moved_vertices':count,'max_displacement_m':maximum,'front_y_below_minus30mm_max_m':frontmax}
    scene.view_layers[0].update()
    result={'margin_m':margin,'falloff_m':falloff,'grid_constraints':len(constraints),'cap_changed_from_v3':False,'restored_prior_cap_fit':restored_prior_fit,'clearance_target':'visible brim upper envelope; hidden solid overlap allowed','hat_meshes':stats}
    hat['psilo_hat_conform_v4']=str(result)
    return result
