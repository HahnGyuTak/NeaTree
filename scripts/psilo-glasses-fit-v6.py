"""Fit full spectacles rims to the final cap without clipping lower arcs."""
import bpy
from mathutils import Vector

def fit_glasses_v6(scene):
    cap=scene.objects['Cap'];group=scene.objects['Glasses']
    saved_scale=group.scale.copy();group.scale=(1,1,1)
    scene.view_layers[0].update()
    evaluated=cap.evaluated_get(bpy.context.evaluated_depsgraph_get())
    points=0
    for name in ['Frame_L','Frame_R','Bridge']:
        obj=scene.objects[name]
        to_cap=cap.matrix_world.inverted() @ obj.matrix_world
        to_curve=obj.matrix_world.inverted() @ cap.matrix_world
        for spline in obj.data.splines:
            for bp in spline.bezier_points:
                probe=to_cap@bp.co
                hit,surface,normal,index=evaluated.ray_cast(Vector((probe.x,-.25,probe.z)),Vector((0,1,0)))
                if not hit: raise ValueError('Spectacles miss cap at '+name)
                # Preserve circular X/Z projection; a gently bowed frame follows
                # the convex cheek with enough space for its 1.2 mm tube radius.
                probe.y=surface.y-.0038
                bp.co=to_curve@probe
                bp.handle_left_type='AUTO';bp.handle_right_type='AUTO'
                points+=1
    # Join the spectacle arms to the newly seated outer rim points.
    for side,sign in [('L',-1),('R',1)]:
        arm=scene.objects['Arm_'+side]
        frame=scene.objects['Frame_'+side]
        outer=max(frame.data.splines[0].bezier_points,key=lambda p:sign*p.co.x)
        arm.data.splines[0].bezier_points[0].co=arm.matrix_world.inverted() @ (frame.matrix_world @ outer.co)
    group.scale=saved_scale
    scene.view_layers[0].update()
    return {'front_curve_points':points,'front_surface_clearance_m':.0038,
            'kept_front_circle_projection':True,'arms_join_outer_rims':True}
