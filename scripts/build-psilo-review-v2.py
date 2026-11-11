"""Build portable Psilo v2 review sources without rendering or app writes.

Usage::

    blender --background --factory-startup \
      --python scripts/build-psilo-review-v2.py -- /new/output-directory

The output must be absent or empty. The builder writes the packed neutral
Psilo-v2.blend, editable Psilo-v2-motion.blend, cap texture and a structural
verification report. It never replaces an existing review or app resource.
"""

import argparse
import ast
import hashlib
import json
import math
from pathlib import Path
import sys

import bpy


def _qualified_name(node):
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        parent = _qualified_name(node.value)
        return parent + '.' + node.attr if parent else None
    return None


class _BaseWithoutPreview(ast.NodeTransformer):
    """Redirect the base's output and remove its preliminary save/render only."""

    def __init__(self, output):
        self.output = output
        self.redirected = 0
        self.skipped_renders = 0
        self.skipped_saves = 0

    def visit_Assign(self, node):
        if any(isinstance(target, ast.Name) and target.id == 'OUT' for target in node.targets):
            self.redirected += 1
            node.value = ast.Constant(str(self.output))
        return self.generic_visit(node)

    def visit_Expr(self, node):
        if isinstance(node.value, ast.Call):
            name = _qualified_name(node.value.func)
            if name == 'bpy.ops.render.render':
                self.skipped_renders += 1
                return None
            if name == 'bpy.ops.wm.save_as_mainfile':
                self.skipped_saves += 1
                return None
            if (name == 'print' and node.value.args
                    and isinstance(node.value.args[0], ast.Constant)
                    and node.value.args[0].value == 'PSILO V2 FRONT RENDER COMPLETE'):
                return None
        return self.generic_visit(node)


def _execute_helper(path, module_name):
    namespace = {'__name__': module_name, '__file__': str(path)}
    exec(compile(path.read_text(), str(path), 'exec'), namespace)
    return namespace


def _verify_keys(scene, neutral=False):
    expected = {'Cap': 'SmileClose', 'EyeDot_L': 'Happy', 'EyeDot_R': 'Happy'}
    names = {}
    for object_name, key_name in expected.items():
        obj = scene.objects.get(object_name)
        keys = obj.data.shape_keys if obj and obj.type == 'MESH' else None
        if keys is None or keys.key_blocks.get(key_name) is None:
            raise RuntimeError('Required expression missing: ' + object_name + '.' + key_name)
        names[object_name] = [key.name for key in keys.key_blocks]
        for key in list(keys.key_blocks)[1:]:
            if not math.isfinite(key.value) or not -0.000001 <= key.value <= 1.000001:
                raise RuntimeError('Invalid shape weight: ' + object_name + '.' + key.name)
            if neutral and abs(key.value) > 0.000001:
                raise RuntimeError('Neutral source has an active expression: ' + object_name + '.' + key.name)
        if neutral and keys.animation_data is not None:
            raise RuntimeError('Neutral source still has shape animation: ' + object_name)
    return names


def build_review(output):
    output = Path(output).expanduser().resolve()
    scripts = Path(__file__).resolve().parent
    source_root = scripts.parent / 'Sources'
    if output == source_root or source_root in output.parents or any(part.endswith('.app') for part in output.parts):
        raise ValueError('Choose a review directory outside application source/resources and app bundles.')
    if output.exists() and (not output.is_dir() or any(output.iterdir())):
        raise FileExistsError('Refusing a nonempty output path: ' + str(output))
    output.mkdir(parents=True, exist_ok=True)
    base_path = scripts / 'blender-psilo-v2.py'
    refinement_path = scripts / 'psilo-sculpt-refinement-v2.py'
    motion_path = scripts / 'psilo-motion-v2.py'
    for path in [base_path, refinement_path, motion_path]:
        if not path.is_file():
            raise FileNotFoundError('Required sibling helper missing: ' + path.name)
    tree = ast.parse(base_path.read_text(), filename=str(base_path))
    transform = _BaseWithoutPreview(output)
    tree = transform.visit(tree)
    if (transform.redirected, transform.skipped_renders, transform.skipped_saves) != (1, 1, 1):
        raise RuntimeError('Base authoring entrypoints changed; inspect before building the review.')
    ast.fix_missing_locations(tree)
    exec(compile(tree, str(base_path), 'exec'),
         {'__name__': 'psilo_review_base', '__file__': str(base_path)})
    refinement = _execute_helper(refinement_path, 'psilo_review_refinement')
    motion = _execute_helper(motion_path, 'psilo_review_motion')
    scene = bpy.context.scene
    refinement['refine_psilo_v2'](scene)
    motion['restore_psilo_rest'](scene)
    required_keys = _verify_keys(scene, neutral=True)
    bpy.ops.file.pack_all()
    scene.render.filepath = '//front-review.png'
    bpy.ops.wm.save_as_mainfile(filepath=str(output / 'Psilo-v2.blend'))

    markers = motion['animate_psilo'](scene)
    controls = motion['_objects'](scene)
    if (scene.frame_start, scene.frame_end, scene.render.fps) != (1, 289, 24):
        raise RuntimeError('Expected the 12-second / 24fps review timeline.')
    transform_checks = 0
    for frame in sorted(set(markers.values()) | {151, 157, 263, 289}):
        scene.frame_set(frame)
        scene.view_layers[0].update()
        _verify_keys(scene)
        for name, obj in controls.items():
            values = [value for row in obj.matrix_world for value in row]
            values += list(obj.location) + list(obj.scale) + list(obj.rotation_quaternion)
            if not all(math.isfinite(value) for value in values):
                raise RuntimeError('Nonfinite transform at frame ' + str(frame) + ': ' + name)
            transform_checks += 1
    scene.frame_set(1)
    bpy.ops.wm.save_as_mainfile(filepath=str(output / 'Psilo-v2-motion.blend'))

    # Prove that the review animation can return to a neutral export pose. The
    # motion file is already saved; this restoration only affects process memory.
    motion['restore_psilo_rest'](scene)
    _verify_keys(scene, neutral=True)
    for name, obj in controls.items():
        if obj.animation_data is not None:
            raise RuntimeError('Restoration left an object action: ' + name)
        for field in ['location', 'scale']:
            expected = obj['psilo_review_rest_' + field]
            if any(abs(value - original) > 0.000001 for value, original in zip(getattr(obj, field), expected)):
                raise RuntimeError('Restoration changed ' + name + '.' + field)
    report = {
        'status': 'passed', 'blender_version': bpy.app.version_string,
        'files': ['Psilo-v2.blend', 'Psilo-v2-motion.blend', 'Psilo-cap-color.png'],
        'required_shape_keys': required_keys, 'control_count': len(controls),
        'duration_seconds': 12, 'fps': 24, 'markers': markers,
        'sampled_transform_checks': transform_checks, 'neutral_restore': 'passed',
        'rendered_images': 0, 'production_approved': False,
        'helper_sha256': {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in [base_path, refinement_path, motion_path]},
        'limitations': ['Structural source verification only; rendered visual review is separate.',
                        'No app resources, runtime morph controller or material bake are created.'],
    }
    (output / 'build-review-report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PSILO_REVIEW_BUILD ' + json.dumps(report))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', help='New or empty directory for review files')
    arguments = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    args = parser.parse_args(arguments)
    build_review(args.output)
