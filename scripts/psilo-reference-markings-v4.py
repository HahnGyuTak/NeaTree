"""Reference-aligned flush cap markings for the unapproved Psilo v4 model.

Call after calibrate_psilo_surface_v4. Fixed pigment samples preserve the
source palette; analytic object-space ellipses avoid UV distortion and jagged
paint edges. Rebuild the base material before reapplying this helper. This is
3D surface pigment, not a camera-facing image. UV baking is required for export.
"""
import bpy
import math

def fit_reference_spots(scene):
    mat=bpy.data.materials['Coral']; nodes=mat.node_tree.nodes; links=mat.node_tree.links
    original=next(n for n in nodes if n.type=='TEX_IMAGE' and n.image and 'cap color' in n.image.name)
    image=original.image;w,h=image.size
    # Use the brightest cream texel of the source swatch, never a baked scene color.
    best=(-1,None)
    for y in range(16,h-16,32):
        for x in range(16,w-16,32):
            index=(y*w+x)*4
            green=image.pixels[index+1]
            if green>best[0]:best=(green,(x/w,y/h,0))
    consumers=[link.to_socket for link in original.outputs['Color'].links]
    base_point=nodes.new('ShaderNodeCombineXYZ');links.new(base_point.outputs[0],original.inputs['Vector'])
    cream=nodes.new('ShaderNodeTexImage');cream.image=image;cream.interpolation='Cubic'
    cream_point=nodes.new('ShaderNodeCombineXYZ')
    for axis,value in zip(('X','Y','Z'),best[1]):cream_point.inputs[axis].default_value=value
    links.new(cream_point.outputs[0],cream.inputs['Vector'])
    coords=nodes.new('ShaderNodeTexCoord');sep=nodes.new('ShaderNodeSeparateXYZ');links.new(coords.outputs['Object'],sep.inputs[0])
    def calc(op,a,b):
        n=nodes.new('ShaderNodeMath');n.operation=op
        for i,value in enumerate((a,b)):
            if isinstance(value,(float,int)):n.inputs[i].default_value=value
            else:links.new(value,n.inputs[i])
        return n.outputs[0]
    # Cap is Z-up, front -Y; centres and radii are in metres, angle in radians.
    merged=0.0
    for cx,cz,rx,rz,angle in [(-.077,-.006,.0145,.0108,.39),(.024,.032,.020,.0123,-.34),(.079,-.009,.0138,.0101,-.55)]:
        dx=calc('SUBTRACT',sep.outputs['X'],cx);dz=calc('SUBTRACT',sep.outputs['Z'],cz)
        u=calc('DIVIDE',calc('ADD',calc('MULTIPLY',dx,math.cos(angle)),calc('MULTIPLY',dz,math.sin(angle))),rx)
        v=calc('DIVIDE',calc('SUBTRACT',calc('MULTIPLY',dz,math.cos(angle)),calc('MULTIPLY',dx,math.sin(angle))),rz)
        distance=calc('ADD',calc('MULTIPLY',u,u),calc('MULTIPLY',v,v))
        edge=nodes.new('ShaderNodeMapRange');edge.clamp=True;edge.inputs['From Min'].default_value=1.01;edge.inputs['From Max'].default_value=.99
        links.new(distance,edge.inputs['Value'])
        merged=calc('MAXIMUM',merged,edge.outputs['Result'])
    mask=calc('MULTIPLY',merged,calc('LESS_THAN',sep.outputs['Y'],-.003))
    paint=nodes.new('ShaderNodeMixRGB');paint.name='Reference spot artwork in cap coordinates'
    links.new(mask,paint.inputs[0]);links.new(original.outputs['Color'],paint.inputs[1]);links.new(cream.outputs['Color'],paint.inputs[2])
    for consumer in consumers:links.new(paint.outputs['Color'],consumer)
    return {'cream_sample':best,'spots_in_object_space':True}
