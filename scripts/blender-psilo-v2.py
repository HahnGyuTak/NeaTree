"""Blender authoring source for Psilo reference-fidelity review v2.

Run in an isolated working scene. Set OUT to a versioned review directory before
executing via Blender MCP, or open a .blend in that directory first. This source
creates real geometry and materials and renders a comparison frame. It does not
replace the approved app resource. Runtime normal-map baking/export is separate.
"""
import bpy
import math
import json
import random
from mathutils import Vector, Matrix

OUT = bpy.path.abspath('//')
PI = math.pi
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
for block in list(bpy.data.materials): bpy.data.materials.remove(block)
SCENE = bpy.context.scene
SCENE.unit_settings.system = 'METRIC'
SCENE.unit_settings.scale_length = 1
SCENE.render.engine = 'CYCLES'
SCENE.cycles.samples = 64
SCENE.cycles.use_denoising = True
SCENE.render.resolution_x = 1100
SCENE.render.resolution_y = 1000
SCENE.render.resolution_percentage = 100
SCENE.view_settings.view_transform = 'AgX'
SCENE.view_settings.look = 'AgX - Medium High Contrast'
SCENE.view_settings.exposure = .35
SCENE.world.color = (.2, .2, .2)


def B(v): return (v[0], -v[2], v[1])
def linear(c): return c/12.92 if c < .04045 else ((c+.055)/1.055)**2.4
def rgb(s): return tuple(linear(int(s[i:i+2],16)/255) for i in (0,2,4))
def material(name, hexvalue, rough=.76):
    m=bpy.data.materials.new(name);m.use_nodes=True
    bs=next(n for n in m.node_tree.nodes if n.type=='BSDF_PRINCIPLED');bs.name='PSILO_Principled'
    bs.inputs['Base Color'].default_value=(*rgb(hexvalue),1)
    bs.inputs['Roughness'].default_value=rough
    bs.inputs['Specular IOR Level'].default_value=.10
    if 'Subsurface Weight' in bs.inputs: bs.inputs['Subsurface Weight'].default_value=.025
    m.diffuse_color=(*rgb(hexvalue),1)
    return m

M={name:material(name,c) for name,c in [('Coral','DB716C'),('Cream','FAE4BA'),('Hat','F7DBAB'),('Sage','879064'),('Ink','35302C'),('Mouth','4C211B')]}
M['Mouth'].node_tree.nodes.get('PSILO_Principled').inputs['Roughness'].default_value=1
M['Mouth'].node_tree.nodes.get('PSILO_Principled').inputs['Subsurface Weight'].default_value=0


def empty(name,parent=None,location=(0,0,0),scale=1):
    o=bpy.data.objects.new(name,None);SCENE.collection.objects.link(o)
    o.empty_display_type='PLAIN_AXES';o.empty_display_size=.01
    o.parent=parent;o.location=B(location);o.scale=(scale,)*3
    return o


def mesh(name,points,faces,mat,parent,subdiv=0,uvs=None):
    data=bpy.data.meshes.new(name+'_mesh');data.from_pydata([B(p) for p in points],[],faces);data.update()
    o=bpy.data.objects.new(name,data);SCENE.collection.objects.link(o);o.parent=parent
    data.materials.append(M[mat])
    for p in data.polygons:p.use_smooth=True
    if uvs:
        uv=data.uv_layers.new(name='UVMap')
        for poly,coords in zip(data.polygons,uvs):
            for loop,coord in zip(poly.loop_indices,coords):uv.data[loop].uv=coord
    if subdiv:
        modifier=o.modifiers.new('Soft sculpt subdivision','SUBSURF');modifier.levels=subdiv;modifier.render_levels=subdiv
    return o


def cm(a,b,c,d,t):
    return .5*((2*b)+(-a+c)*t+(2*a-5*b+4*c-d)*t*t+(-a+3*b-3*c+d)*t*t*t)
def smooth_profile(controls,count):
    result=[]
    for j in range(count):
        at=j/(count-1)*(len(controls)-1);i=min(int(at),len(controls)-2);t=at-i
        a,b,c,d=[controls[max(0,min(len(controls)-1,k))] for k in (i-1,i,i+1,i+2)]
        result.append(tuple(cm(a[n],b[n],c[n],d[n],t) for n in range(2)))
    return result


def lathe(name,profile,rx,rz,mat,parent,segments=40,subdiv=1,offset=(0,0,0),tilt=0,cap_uv=False):
    points=[];faces=[];uvs=[]
    for i,(r,h) in enumerate(profile):
        for j in range(segments):
            phi=2*PI*j/segments
            x=rx*r*math.cos(phi);z=rz*r*math.sin(phi)
            y=h
            if name=='Cap':
                y+=.0017*math.cos(phi+.6)*r*r-.0035*max(0,math.sin(phi))**4*r**4+.007*(abs(math.cos(phi))*r)**4
                x+=.0015*math.sin(phi)*r*r
            xx=x*math.cos(tilt)-y*math.sin(tilt)
            yy=x*math.sin(tilt)+y*math.cos(tilt)
            points.append((xx+offset[0],yy+offset[1],z+offset[2]))
    for i in range(len(profile)-1):
        for j in range(segments):
            a=i*segments+j;b=i*segments+(j+1)%segments;c=b+segments;d=a+segments
            faces.append((a,b,c,d));uvs.append(((j/segments,i/(len(profile)-1)),((j+1)/segments,i/(len(profile)-1)),((j+1)/segments,(i+1)/(len(profile)-1)),(j/segments,(i+1)/(len(profile)-1))))
    return mesh(name,points,faces,mat,parent,subdiv,uvs if cap_uv else None)


def sphere(name,parent,loc,scale,mat,segments=32,rings=16):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments,ring_count=rings,location=B(loc))
    o=bpy.context.object;o.name=name;o.parent=parent
    # Object scale must map to Blender's native XYZ basis as well.
    o.scale=(scale[0],scale[2],scale[1]);o.data.materials.append(M[mat])
    for p in o.data.polygons:p.use_smooth=True
    return o


def tube(name,parent,controls,radii,mat,sides=10,subdiv=1):
    path=[];rr=[];count=(len(controls)-1)*3+1
    for j in range(count):
        at=j/(count-1)*(len(controls)-1);i=min(int(at),len(controls)-2);t=at-i
        pp=[controls[max(0,min(len(controls)-1,k))] for k in (i-1,i,i+1,i+2)]
        rad=[radii[max(0,min(len(radii)-1,k))] for k in (i-1,i,i+1,i+2)]
        path.append(Vector(tuple(cm(pp[0][n],pp[1][n],pp[2][n],pp[3][n],t) for n in range(3))))
        rr.append(max(.00005,cm(*rad,t)))
    points=[];faces=[]
    for i,p in enumerate(path):
        tangent=(path[min(i+1,len(path)-1)]-path[max(i-1,0)]).normalized()
        axis=Vector((0,0,1)) if abs(tangent.z)<.8 else Vector((0,1,0))
        u=tangent.cross(axis).normalized();v=tangent.cross(u).normalized()
        for j in range(sides):
            phi=2*PI*j/sides;points.append(tuple(p+rr[i]*(math.cos(phi)*u+math.sin(phi)*v)))
    for i in range(len(path)-1):
        for j in range(sides):
            a=i*sides+j;b=i*sides+(j+1)%sides;c=b+sides;d=a+sides
            faces.append((a,b,c,d))
    faces.extend([tuple(reversed(range(sides))),tuple((len(path)-1)*sides+j for j in range(sides))])
    return mesh(name,points,faces,mat,parent,subdiv)


def bezier_curve(name,parent,points,mat,radius=.0009):
    curve=bpy.data.curves.new(name+'_curve','CURVE');curve.dimensions='3D';curve.resolution_u=3
    curve.bevel_depth=radius;curve.bevel_resolution=1;curve.use_fill_caps=True
    spline=curve.splines.new('BEZIER');spline.bezier_points.add(len(points)-1)
    for b,p in zip(spline.bezier_points,points):b.co=B(p);b.handle_left_type='AUTO';b.handle_right_type='AUTO'
    obj=bpy.data.objects.new(name,curve);SCENE.collection.objects.link(obj);obj.parent=parent;curve.materials.append(M[mat]);return obj


psilo=empty('Psilo')
base=empty('Base',psilo)
sphere('Pedestal',base,(0,.020,0),(.050,.022,.036),'Cream',48,24)
head=empty('Head',psilo,(0,.06,0))
CAP_PROFILE=smooth_profile([(0,.029),(.35,.028),(.72,.028),(.95,.028),(1,.034),(1,.043),(.94,.055),(.78,.077),(.56,.100),(.31,.113),(0,.116)],33)
CAP_PROFILE=list(reversed(CAP_PROFILE))
cap=lathe('Cap',[(r,h-.06) for r,h in CAP_PROFILE],.105,.059,'Coral',head,64,2,cap_uv=True)
def face_depth(x,y):
    upper=CAP_PROFILE[:next(i for i,p in enumerate(CAP_PROFILE) if p[0]>=.995)+1]
    for i in range(len(upper)-1):
        r0,h0=upper[i];r1,h1=upper[i+1]
        if h0>=y>=h1:
            r=r0+(r1-r0)*(h0-y)/(h0-h1)
            return .059*math.sqrt(max(.01,r*r-(x/.105)**2))
    return .056

# One small UV color image keeps printed spots perfectly flush with the sculpt.
TEX=1536
image=bpy.data.images.new('Psilo cap color',width=TEX,height=TEX,alpha=False)
pixels=[0.0]*(TEX*TEX*4)
coral=rgb('DB716C');cream=rgb('FAE4BA')
spots=[(-.071,.051,.0145,.0115),(.024,.083,.019,.014),(.079,.049,.0125,.011)]
for row in range(TEX):
    v=row/(TEX-1);pos=v*(len(CAP_PROFILE)-1);a=min(int(pos),len(CAP_PROFILE)-2);t=pos-a
    r=CAP_PROFILE[a][0]*(1-t)+CAP_PROFILE[a+1][0]*t
    h=CAP_PROFILE[a][1]*(1-t)+CAP_PROFILE[a+1][1]*t
    for col in range(TEX):
        phi=2*PI*col/(TEX-1);x=.105*r*math.cos(phi)+.0015*math.sin(phi)*r*r
        y=h+.0017*math.cos(phi+.6)*r*r;front=math.sin(phi)>0
        inside=front and any(((x-cx)/rx)**2+((y-cy)/ry)**2 < 1 for cx,cy,rx,ry in spots)
        c=cream if inside else coral
        # A tiny neutral grain is baked into this sole texture, not a runtime shader.
        grain=(math.sin(col*18.231+row*7.13)*math.sin(col*.371-row*5.37))*.004
        index=(row*TEX+col)*4;pixels[index:index+4]=[max(0,min(1,q+grain)) for q in c]+[1]
image.pixels.foreach_set(pixels);image.filepath_raw=(OUT+'/Psilo-cap-color.png');image.file_format='PNG';image.save();image.pack()
nodes=M['Coral'].node_tree.nodes;tex=nodes.new('ShaderNodeTexImage');tex.image=image;tex.interpolation='Linear'
M['Coral'].node_tree.links.new(tex.outputs['Color'],nodes.get('PSILO_Principled').inputs['Base Color'])

horns=empty('Horns',head)
for sign,label in [(-1,'L'),(1,'R')]:
    o=sphere('Horn_'+label,horns,(sign*.082,.095-.06,.008),(.020,.026,.018),'Cream',48,32)
    # Bend a closed UV sphere into a soft cashew, preserving perfectly rounded ends.
    for v in o.data.vertices:
        h=v.co.z
        v.co.x += sign*(.35*h-1.10*h*h+.40*(1-h*h)*max(0,-sign*v.co.x)**2)
    bpy.ops.object.select_all(action='DESELECT');o.select_set(True);bpy.context.view_layer.objects.active=o
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    tip=sphere('HornRoundTip_'+label,horns,(sign*.066,.113-.06,.008),(.007,.007,.012),'Cream',32,24)
    o.select_set(True);tip.select_set(True);bpy.context.view_layer.objects.active=o;bpy.ops.object.join()
    rem=o.modifiers.new('Unified soft horn','REMESH');rem.mode='VOXEL';rem.voxel_size=.00085;rem.use_smooth_shade=True
    bpy.ops.object.modifier_apply(modifier=rem.name)
    smooth=o.modifiers.new('Soft sculpt polish','SMOOTH');smooth.factor=1.0;smooth.iterations=22
    bpy.ops.object.modifier_apply(modifier=smooth.name)
    mod=o.modifiers.new('Horn smooth surface','SUBSURF');mod.levels=1
hat=empty('Hat',head)
hat_origin=(-.002,.047,-.003)
# Thick softly rolled brim, dipping at the front like the original gardener hat.
brim=lathe('Brim',[(0,.008),(.52,.009),(.72,.004),(.90,-.002),(1,-.009),(1,-.012),(.96,-.014),(.78,-.007),(.50,.002),(0,.003)],.070,.047,'Hat',hat,64,2,hat_origin,.19)
for v in brim.data.vertices:
    xx,zz,yy=v.co.x,-v.co.y,v.co.z
    front=max(0,zz/.046)
    v.co.z -= .005*front*front
    v.co.z += .010*front*max(0,min(1,(xx+.012)/.05))**1.5
    v.co.y -= .003*front
for v in brim.data.vertices:
    right=max(0,min(1,(v.co.x-.020)/.045));right=right*right*(3-2*right)
    front=max(0,min(1,(-v.co.y+.005)/.045));front=front*front*(3-2*front)
    v.co.z-=.009*right*front
lathe('Crown',[(0,.037),(.25,.036),(.50,.032),(.73,.026),(.90,.017),(1,.005),(1,.001)],.046,.035,'Hat',hat,64,2,hat_origin,.19)
lathe('Band',[(.943,.013),(.975,.010),(1.004,.005),(1.009,.003)],.046,.035,'Sage',hat,64,1,hat_origin,.19)

for v in list(bpy.data.objects['Crown'].data.vertices)[-64:]: v.co.z-=.006
for n in ['Crown','Band']:
    bpy.data.objects[n].location.y=-.006
    bpy.data.objects[n].location.z=.0015

for sign,label in [(-1,'L'),(1,'R')]:
    eye=empty('eye_'+label,head,(sign*.031,-.006,face_depth(sign*.031,.054)+.001))
    sphere('EyeDot_'+label,eye,(0,0,0),(.0031,.00325,.0017),'Ink',20,12)
bpy.context.view_layer.update()
bpy.context.view_layer.objects.active=cap
for mod in list(cap.modifiers):
    bpy.ops.object.modifier_apply(modifier=mod.name)
# Ray cast in cap local coordinates to seat facial pieces exactly on the surface.
hit,point,normal,idx=cap.ray_cast(Vector((0,-.2,-.016)),Vector((0,1,0)))
mouth_front=-point.y if hit else face_depth(0,.044)
cut=sphere('MouthCut',head,(0,-.016,mouth_front-.0005),(.0058,.0040,.0045),'Mouth',40,24)
bpy.context.view_layer.update()
bpy.context.view_layer.objects.active=cap
modifier=cap.modifiers.new('True inset mouth','BOOLEAN');modifier.operation='DIFFERENCE';modifier.object=cut
bpy.ops.object.modifier_apply(modifier=modifier.name)
bpy.data.objects.remove(cut,do_unlink=True)
mouth=empty('mouth_idle',head,(0,-.016,mouth_front-.0015))
sphere('MouthCavity',mouth,(0,0,-.0015),(.0054,.0037,.0022),'Mouth',40,24)
M['Interior']=material('Interior','AE4938',1)
M['Interior'].node_tree.nodes.get('PSILO_Principled').inputs['Subsurface Weight'].default_value=0
sphere('MouthLowerGlow',mouth,(0,-.0017,-.0010),(.0040,.0014,.0003),'Interior',32,16)
proud=empty('mouth_proud',head,(0,-.016,mouth_front+.0003),.001)
M['SkinDetail']=M['Coral'].copy();M['SkinDetail'].name='SkinDetailMatched'
uniform=M['SkinDetail'].node_tree.nodes.new('ShaderNodeCombineXYZ');uniform.inputs['X'].default_value=.75;uniform.inputs['Y'].default_value=.5
for n in M['SkinDetail'].node_tree.nodes:
    if n.type=='TEX_IMAGE': M['SkinDetail'].node_tree.links.new(uniform.outputs['Vector'],n.inputs['Vector'])
backing=sphere('SmileBacking',proud,(0,0,-.0003),(.0063,.0044,.0006),'SkinDetail',40,20)
for v in backing.data.vertices: v.co.y+=.3
bezier_curve('Smile',proud,[(-.005,.001,0),(0,-.002,0),(.005,.001,0)],'Ink',.00065)

happy=empty('ProudEyes',head,scale=.001)
for sign,label in [(-1,'L'),(1,'R')]:
    pts=[(sign*.031-.0035+i*.0007,-.006+.0015*math.sin(PI*i/10),face_depth(sign*.031,.054)+.002) for i in range(11)]
    bezier_curve('ProudEye_'+label,happy,pts,'Ink',.00065)

glasses=empty('Glasses',head,(0,-.006,.056),.001)
for sign,label in [(-1,'L'),(1,'R')]:
    pts=[(sign*.029+.0128*math.cos(2*PI*i/12),.0128*math.sin(2*PI*i/12),0) for i in range(13)]
    bezier_curve('Frame_'+label,glasses,pts,'Ink',.0012)
    bezier_curve('Arm_'+label,glasses,[(sign*.041,0,0),(sign*.050,0,-.015),(sign*.051,-.003,-.027)],'Ink',.00075)
bezier_curve('Bridge',glasses,[(-.016,0,0),(0,.002,0),(.016,0,0)],'Ink',.00075)
errors=empty('ErrorEyes',head,scale=.001)
for sign,label in [(-1,'L'),(1,'R')]:
    sp=empty('spiral_'+label,errors,(sign*.031,-.006,face_depth(sign*.031,.054)+.003))
    pts=[]
    for i in range(31):
        a=i/30*PI*4.4;r=.0005+.005*i/30;pts.append((r*math.cos(a),r*math.sin(a),0))
    bezier_curve('SpiralCurve_'+label,sp,pts,'Ink',.0005)

props=empty('Props',psilo)
for i,loc in enumerate([(-.082,.014,.039),(-.069,.018,.047),(.081,.016,.035)]):
    file=empty('file_'+str(i),props,loc,.001)
    def box(name,loc,size,mat,bevel):
        bpy.ops.mesh.primitive_cube_add(size=1,location=B(loc));o=bpy.context.object;o.name=name;o.parent=file;o.scale=(size[0],size[2],size[1])
        bpy.ops.object.transform_apply(location=False,rotation=False,scale=True);o.data.materials.append(M[mat])
        b=o.modifiers.new('Paper edge bevel','BEVEL');b.width=bevel;b.segments=2
        o.modifiers.new('Weighted corner normals','WEIGHTED_NORMAL')
    box('Folder', (0,0,0),(.049,.0018,.034),'Hat',.0012)
    box('FolderTab',(-.010,.0002,-.017),(.018,.0018,.006),'Hat',.001)
    box('Document',(0,.0018,.001),(.042,.0006,.028),'Cream',.0007)
    file.rotation_euler=(math.radians(35),0,math.radians([-8,7,8][i]))

# Fine paper grain: subtle in silhouette, visible in highlights.
for name in ['Coral','Cream','Hat','Sage','SkinDetail']:
    mat=M[name];nodes=mat.node_tree.nodes;links=mat.node_tree.links
    coord=nodes.new('ShaderNodeTexCoord')
    noise=nodes.new('ShaderNodeTexNoise');noise.inputs['Scale'].default_value=260;noise.inputs['Detail'].default_value=2;noise.inputs['Roughness'].default_value=.72
    links.new(coord.outputs['Generated'],noise.inputs['Vector'])
    bump=nodes.new('ShaderNodeBump');bump.inputs['Strength'].default_value=.30;bump.inputs['Distance'].default_value=.00022
    links.new(noise.outputs['Fac'],bump.inputs['Height']);links.new(bump.outputs['Normal'],nodes.get('PSILO_Principled').inputs['Normal'])

for o in list(bpy.context.scene.objects):
    if o.type=='MESH':
        bpy.ops.object.select_all(action='DESELECT');o.select_set(True);bpy.context.view_layer.objects.active=o
        bpy.ops.object.mode_set(mode='EDIT');bpy.ops.mesh.select_all(action='SELECT');bpy.ops.mesh.normals_make_consistent(inside=False);bpy.ops.object.mode_set(mode='OBJECT')
# Studio-only geometry lives outside Psilo and is never selected for export.
bpy.ops.mesh.primitive_plane_add(size=200, location=(0,0,.002))
floor=bpy.context.object;floor.name='STUDIO_Floor';floor.hide_render=True;floor.data.materials.append(material('Studio ivory','F2EEE8',.9))
def aim(obj,target):obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler()
def light(name,location,power,size,color):
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape='DISK';data.size=size;data.color=color
    o=bpy.data.objects.new(name,data);SCENE.collection.objects.link(o);o.location=location;aim(o,(0,0,.065))
light('STUDIO_Key',(-.18,-.22,.28),1.7,.30,(1,.98,.95))
light('STUDIO_Fill',(.23,-.13,.16),1.0,.30,(1,.98,.94))
light('STUDIO_Rim',(.10,.16,.21),1,.18,(1,.96,.87))
camera_data=bpy.data.cameras.new('STUDIO_Camera');camera=bpy.data.objects.new('STUDIO_Camera',camera_data);SCENE.collection.objects.link(camera)
camera_data.type='ORTHO';camera_data.ortho_scale=.250;camera_data.lens=70
camera.location=(0,-.45,.105);aim(camera,(0,0,.077));SCENE.camera=camera
SCENE.render.image_settings.file_format='PNG';SCENE.render.film_transparent=True
SCENE.world.use_nodes=True;next(n for n in SCENE.world.node_tree.nodes if n.type=='BACKGROUND').inputs['Color'].default_value=(.85,.85,.85,1)
next(n for n in SCENE.world.node_tree.nodes if n.type=='BACKGROUND').inputs['Strength'].default_value=.55

# Reopen in a useful material-preview camera view rather than a default cube view.
for area in bpy.context.screen.areas if bpy.context.screen else []:
    if area.type=='VIEW_3D':
        area.spaces.active.region_3d.view_perspective='CAMERA'
        area.spaces.active.shading.type='MATERIAL'
image.filepath='//Psilo-cap-color.png'
bpy.ops.file.pack_all()
SCENE.render.filepath=OUT+'/front-review.png'
bpy.ops.wm.save_as_mainfile(filepath=OUT+'/Psilo-v2.blend')
bpy.ops.render.render(write_still=True)
print('PSILO V2 FRONT RENDER COMPLETE')
