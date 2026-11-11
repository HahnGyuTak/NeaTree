"""Blender-native editable Psilo authoring scene and lightweight USD export.

Run with Blender --background --python scripts/blender-psilo.py -- REPO_PATH.
This builds new Blender geometry, subdivision surfaces, UV art and materials.
It does not import the earlier rejected USD prototype.
"""
import bpy
import math
import json
import random
import subprocess
import sys
from pathlib import Path
from mathutils import Vector, Matrix

ROOT = Path(sys.argv[sys.argv.index('--') + 1]) if '--' in sys.argv else Path(__file__).resolve().parents[1]
OUT = ROOT / 'assets/psilo/blender'
OUT.mkdir(parents=True, exist_ok=True)
PI = math.pi
bpy.ops.object.select_all(action='SELECT')
bpy.ops.object.delete(use_global=False)
for block in list(bpy.data.materials): bpy.data.materials.remove(block)
SCENE = bpy.context.scene
SCENE.unit_settings.system = 'METRIC'
SCENE.unit_settings.scale_length = 1
SCENE.render.engine = 'CYCLES'
SCENE.cycles.samples = 48
SCENE.cycles.use_denoising = True
SCENE.render.resolution_x = 1200
SCENE.render.resolution_y = 1000
SCENE.render.resolution_percentage = 100
SCENE.view_settings.view_transform = 'AgX'
SCENE.world.color = (.2, .2, .2)


def B(v): return (v[0], -v[2], v[1])
def linear(c): return c/12.92 if c < .04045 else ((c+.055)/1.055)**2.4
def rgb(s): return tuple(linear(int(s[i:i+2],16)/255) for i in (0,2,4))
def material(name, hexvalue, rough=.72):
    m=bpy.data.materials.new(name);m.use_nodes=True
    bs=m.node_tree.nodes.get('Principled BSDF')
    bs.inputs['Base Color'].default_value=(*rgb(hexvalue),1)
    bs.inputs['Roughness'].default_value=rough
    if 'Subsurface Weight' in bs.inputs: bs.inputs['Subsurface Weight'].default_value=.025
    m.diffuse_color=(*rgb(hexvalue),1)
    return m

M={name:material(name,c) for name,c in [('Coral','D96F62'),('Cream','F4E3C4'),('Hat','D9C69E'),('Sage','879064'),('Ink','35302C'),('Mouth','4C211B')]}
M['Mouth'].node_tree.nodes.get('Principled BSDF').inputs['Roughness'].default_value=1


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
                y+=.0017*math.cos(phi+.6)*r*r
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
sphere('Pedestal',base,(0,.022,0),(.042,.017,.030),'Cream',40,20)
head=empty('Head',psilo,(0,.06,0))
CAP_PROFILE=smooth_profile([(0,.044),(.32,.036),(.72,.030),(.94,.030),(1,.037),(.97,.045),(.84,.061),(.64,.078),(.42,.094),(.20,.102),(0,.104)],21)
# Reverse so the outside normals face outwards (top to bottom radial traversal).
CAP_PROFILE=list(reversed(CAP_PROFILE))
cap=lathe('Cap',[(r,h-.06) for r,h in CAP_PROFILE],.105,.047,'Coral',head,48,1,cap_uv=True)

# One small UV color image keeps printed spots perfectly flush with the sculpt.
TEX=768
image=bpy.data.images.new('Psilo cap color',width=TEX,height=TEX,alpha=False)
pixels=[0.0]*(TEX*TEX*4)
coral=rgb('D96F62');cream=rgb('F4E3C4')
spots=[(-.063,.057,.016,.007),(.030,.085,.018,.010),(.073,.051,.013,.0075)]
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
        grain=(math.sin(col*18.231+row*7.13)*math.sin(col*.371-row*5.37))*.003
        index=(row*TEX+col)*4;pixels[index:index+4]=[max(0,min(1,q+grain)) for q in c]+[1]
image.pixels.foreach_set(pixels);image.filepath_raw=str(OUT/'Psilo-cap-color.png');image.file_format='PNG';image.save();image.pack()
nodes=M['Coral'].node_tree.nodes;tex=nodes.new('ShaderNodeTexImage');tex.image=image;tex.interpolation='Linear'
M['Coral'].node_tree.links.new(tex.outputs['Color'],nodes.get('Principled BSDF').inputs['Base Color'])

horns=empty('Horns',head)
horn_scope={'__name__':'psilo_approved_horn_helper'}
horn_source=ROOT/'scripts/psilo-short-horns-v5.py'
exec(compile(horn_source.read_text(),str(horn_source),'exec'),horn_scope)
horn_scope['apply_psilo_short_horns_v5'](SCENE,segments=24,rings=17,subdivision=1,front_offset=-.003)

hat=empty('Hat',head)
hat_origin=(-.007,.040,-.007)
lathe('Brim',[(0,0),(.70,0),(.94,-.001),(1,-.003),(1,-.005),(.96,-.007),(.75,-.005),(0,-.004)],.059,.042,'Hat',hat,48,1,hat_origin,.13)
lathe('Crown',[(0,.032),(.25,.031),(.50,.027),(.72,.021),(.90,.012),(1,.002),(1,-.001)],.038,.030,'Hat',hat,40,1,hat_origin,.13)
lathe('Band',[(.956,.009),(.98,.007),(1.005,.003),(1.008,.001)],.038,.030,'Sage',hat,40,0,hat_origin,.13)

for sign,label in [(-1,'L'),(1,'R')]:
    eye=empty('eye_'+label,head,(sign*.031,-.007,.040))
    sphere('EyeDot_'+label,eye,(0,0,0),(.0019,.00215,.0012),'Ink',20,12)
mouth=empty('mouth_idle',head,(0,-.019,.0475))
sphere('MouthCavity',mouth,(0,0,0),(.0048,.0030,.00015),'Mouth',24,12)
# Dark lower interior inset makes the mouth read as an opening in the face.
proud=empty('mouth_proud',head,(0,-.019,.0475),.001)
bezier_curve('Smile',proud,[(-.005,.001,0),(0,-.002,0),(.005,.001,0)],'Ink',.00065)

glasses=empty('Glasses',head,(0,-.006,.045),.001)
for sign,label in [(-1,'L'),(1,'R')]:
    pts=[(sign*.029+.0128*math.cos(2*PI*i/12),.0128*math.sin(2*PI*i/12),0) for i in range(13)]
    bezier_curve('Frame_'+label,glasses,pts,'Ink',.0009)
    bezier_curve('Arm_'+label,glasses,[(sign*.041,0,0),(sign*.050,0,-.015),(sign*.051,-.003,-.027)],'Ink',.00075)
bezier_curve('Bridge',glasses,[(-.016,0,0),(0,.002,0),(.016,0,0)],'Ink',.00075)
errors=empty('ErrorEyes',head,scale=.001)
for sign,label in [(-1,'L'),(1,'R')]:
    sp=empty('spiral_'+label,errors,(sign*.031,-.007,.043))
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

# Studio-only geometry lives outside Psilo and is never selected for export.
bpy.ops.mesh.primitive_plane_add(size=200, location=(0,0,.002))
floor=bpy.context.object;floor.name='STUDIO_Floor';floor.data.materials.append(material('Studio ivory','F2EEE8',.9))
def aim(obj,target):obj.rotation_euler=(Vector(target)-obj.location).to_track_quat('-Z','Y').to_euler()
def light(name,location,power,size,color):
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape='DISK';data.size=size;data.color=color
    o=bpy.data.objects.new(name,data);SCENE.collection.objects.link(o);o.location=location;aim(o,(0,0,.065))
light('STUDIO_Key',(-.18,-.22,.28),1.4,.24,(1,.92,.82))
light('STUDIO_Fill',(.23,-.13,.16),.7,.22,(.83,.90,1))
light('STUDIO_Rim',(.10,.16,.21),1,.18,(1,.96,.87))
camera_data=bpy.data.cameras.new('STUDIO_Camera');camera=bpy.data.objects.new('STUDIO_Camera',camera_data);SCENE.collection.objects.link(camera)
camera_data.type='ORTHO';camera_data.ortho_scale=.255;camera_data.lens=70
camera.location=(0,-.45,.071);aim(camera,(0,0,.071));SCENE.camera=camera
SCENE.render.image_settings.file_format='PNG';SCENE.render.film_transparent=False
SCENE.world.use_nodes=True;SCENE.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.7,.74,.8,1)
SCENE.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.35

# Reopen in a useful material-preview camera view rather than a default cube view.
for area in bpy.context.screen.areas if bpy.context.screen else []:
    if area.type=='VIEW_3D':
        area.spaces.active.region_3d.view_perspective='CAMERA'
        area.spaces.active.shading.type='MATERIAL'
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'Psilo.blend'))
SCENE.render.filepath=str(OUT/'Psilo-front.png');bpy.ops.render.render(write_still=True)
camera.location=(.19,-.40,.12);aim(camera,(0,0,.071));SCENE.render.filepath=str(OUT/'Psilo-three-quarter.png');bpy.ops.render.render(write_still=True)
camera.location=(0,-.45,.071);aim(camera,(0,0,.071))

# Actual Blender USD export, keeping separate named rig controls. A temporary
# evaluated copy changes every local geometry/control basis from Blender Z-up to
# app Y-up. The editable authoring scene stays standard Blender Z-up.
bpy.ops.object.select_all(action='DESELECT')
sources=[psilo]+list(psilo.children_recursive)
original_names={obj:obj.name for obj in sources}
for obj in sources:obj.name='AUTHOR_'+original_names[obj]
conversion=Matrix.Rotation(-PI/2,4,'X')
inverse=conversion.inverted()
deps=bpy.context.evaluated_depsgraph_get()
copies={}
for obj in sources:
    if obj.type in {'MESH','CURVE'}:
        data=bpy.data.meshes.new_from_object(obj.evaluated_get(deps),depsgraph=deps)
        data.transform(conversion)
        new=bpy.data.objects.new(original_names[obj],data)
    else:new=bpy.data.objects.new(original_names[obj],None)
    SCENE.collection.objects.link(new);copies[obj]=new
for obj,new in copies.items():
    new.parent=copies.get(obj.parent)
    new.matrix_local=conversion@obj.matrix_local@inverse
export_root=copies[psilo]
def select_tree(obj):
    obj.select_set(True)
    for child in obj.children:select_tree(child)
select_tree(export_root);bpy.context.view_layer.objects.active=export_root
props_api=bpy.ops.wm.usd_export.get_rna_type().properties
kwargs=dict(filepath=str(OUT/'Psilo-app.usda'),selected_objects_only=True,export_animation=False,
            export_materials=True,export_textures=True,overwrite_textures=True,export_normals=True,
            export_uvmaps=True,export_meshes=True,export_cameras=False,export_lights=False,
            generate_materialx_network=False,convert_orientation=False)
kwargs={key:value for key,value in kwargs.items() if key in props_api}
bpy.ops.wm.usd_export(**kwargs)
stage=OUT/'Psilo-app.usda'
stage.write_text(stage.read_text().replace('upAxis = "Z"','upAxis = "Y"',1).rstrip()+'\n')
subprocess.run(['usdcat',str(stage),'-o',str(OUT/'Psilo.usdc')],check=True)
package=OUT/'Psilo.usdz'
if package.exists():package.unlink()
subprocess.run(['usdzip','--asset',str(OUT/'Psilo.usdc'),str(package)],check=True)
subprocess.run(['usdchecker','--arkit',str(package)],check=True)
triangles=0;mesh_count=0
for obj in copies.values():
    if obj.type=='MESH':
        obj.data.calc_loop_triangles();triangles+=len(obj.data.loop_triangles);mesh_count+=1
metrics=dict(name='Psilo',source='Blender 5.3',triangles=triangles,meshes=mesh_count,materials=6,textures=1,texture_resolution=[TEX,TEX],bytes=package.stat().st_size)
(OUT/'model-metrics.json').write_text(json.dumps(metrics,indent=2)+'\n')
for obj in copies.values():bpy.data.objects.remove(obj,do_unlink=True)
for obj,name in original_names.items():obj.name=name
for frame,mode in [(1,'idle'),(30,'idle'),(52,'work'),(74,'work'),(96,'proud'),(118,'proud'),(140,'error'),(162,'error'),(184,'idle')]:
    glasses.scale=(1 if mode=='work' else .001,)*3
    errors.scale=(1 if mode=='error' else .001,)*3
    proud.scale=(1 if mode=='proud' else .001,)*3
    mouth.scale=(.001 if mode=='proud' else 1,)*3
    for eye in [bpy.data.objects['eye_L'],bpy.data.objects['eye_R']]:
        eye.scale=(.001 if mode=='error' else 1,)*3;eye.keyframe_insert('scale',frame=frame)
    for file in props.children:
        file.scale=(1 if mode=='work' else .001,)*3;file.keyframe_insert('scale',frame=frame)
    for obj in [glasses,errors,proud,mouth]:obj.keyframe_insert('scale',frame=frame)
    head.rotation_euler=(math.radians(7 if mode=='work' else 0),math.radians(-6 if mode=='error' else 0),math.radians(4 if mode=='proud' else 0))
    head.keyframe_insert('rotation_euler',frame=frame)
SCENE.frame_end=184;SCENE.frame_set(1)
image.filepath='//Psilo-cap-color.png'
SCENE.render.filepath='//Psilo-front.png'
bpy.ops.wm.save_as_mainfile(filepath=str(OUT/'Psilo.blend'))
print('PSILO_OUTPUT '+json.dumps(metrics))
