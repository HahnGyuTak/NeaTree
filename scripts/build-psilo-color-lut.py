"""Sample Blender's display transform into NeaTree's small runtime color table.

Run with Blender 5.3, from any working directory:
  blender -b --python scripts/build-psilo-color-lut.py -- --out /tmp/psilo-lut

The output is numerical Image.save_render output, not a copied upstream config,
LUT or shader implementation. The chosen Blender color-management files must
match the hashes recorded in provenance.json for byte-identical reproduction.
"""
import argparse
import array
import hashlib
import json
import math
import struct
import sys
import tempfile
from pathlib import Path

import bpy

parser = argparse.ArgumentParser()
parser.add_argument('--out', type=Path, required=True)
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:])
out = args.out.resolve()
if out.exists() and any(out.iterdir()):
    raise ValueError('Choose a new empty output directory.')
out.mkdir(parents=True, exist_ok=True)
size = 33
scene = bpy.data.scenes.new('Psilo display transform numerical sample')
scene.display_settings.display_device = 'sRGB'
scene.view_settings.view_transform = 'AgX'
scene.view_settings.look = 'AgX - Medium High Contrast'
scene.view_settings.exposure = .4
scene.view_settings.gamma = 1
scene.view_settings.use_curve_mapping = False
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGB'
scene.render.image_settings.color_depth = '16'
scene.render.image_settings.color_management = 'FOLLOW_SCENE'
scene.render.use_stamp = False
scene.render.use_stamp_filename = False
scene.render.use_stamp_note = False

# Blender images and Metal textures both use X-fastest row order. The flattening
# below maps red to X, green to Y and blue to Z in the final 3D texture.
pixels = array.array('f')
for blue in range(size):
    for green in range(size):
        for red in range(size):
            pixels.extend((2 ** (-12 + 16 * red / (size - 1)),
                           2 ** (-12 + 16 * green / (size - 1)),
                           2 ** (-12 + 16 * blue / (size - 1)), 1))
source = bpy.data.images.new('Psilo display transform input', width=size * size,
                             height=size, alpha=True, float_buffer=True)
source.colorspace_settings.name = 'Linear Rec.709'
source.pixels.foreach_set(pixels)
source.update()
with tempfile.TemporaryDirectory(prefix='psilo-lut-', dir=out) as temporary:
    encoded_path = Path(temporary) / 'display-transform.png'
    source.save_render(filepath=str(encoded_path), scene=scene)
    encoded = bpy.data.images.load(str(encoded_path), check_existing=False)
    # Keep display-encoded numerical output, without undoing the sRGB transfer.
    encoded.colorspace_settings.name = 'Non-Color'
    converted = array.array('f', [0.0]) * (size ** 3 * 4)
    encoded.pixels.foreach_get(converted)
    bpy.data.images.remove(encoded)
assert len(converted) == 33 ** 3 * 4
assert all(math.isfinite(value) and 0 <= value <= 1 for value in converted)
payload = struct.pack('<' + str(len(converted)) + 'e', *converted)
assert len(payload) == 287496
lut = out / 'PsiloDisplayTransform.rgba16float'
lut.write_bytes(payload)

resource_root = Path(bpy.utils.resource_path('LOCAL')) / 'datafiles' / 'colormanagement'
color_files = ['config.ocio', 'luts/AgX_Base_sRGB.cube']
inputs = [{'relative_path': name,
           'sha256': hashlib.sha256((resource_root / name).read_bytes()).hexdigest()}
          for name in color_files]
metadata = {
    'generator': 'scripts/build-psilo-color-lut.py',
    'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    'method': 'float image -> Blender Image.save_render 16-bit PNG -> Non-Color numerical decode -> IEEE754 half',
    'blender_version': bpy.app.version_string,
    'blender_build_hash': bpy.app.build_hash.decode(),
    'color_management_inputs': inputs,
    'display': 'sRGB', 'view_transform': 'AgX',
    'look': 'AgX - Medium High Contrast',
    'lut_exposure_stops': .4, 'gamma': 1,
    'dimension': 33, 'channels': 'RGBA', 'encoding': 'little-endian IEEE754 binary16',
    'layout': 'red/X fastest, green/Y next, blue/Z slowest',
    'input_linear_range': [2 ** -12, 16],
    'input_shaper': 'clamp((log2(max(linearRGB, 2^-12)) + 12) / 16, 0, 1)',
    'output_transfer': 'display-encoded sRGB',
    'runtime_calibration_stops_not_baked_into_lut': 1.2,
    'runtime_output': 'decode sampled sRGB to linear before writing an sRGB Metal target',
    'filename': lut.name, 'bytes': len(payload),
    'sha256': hashlib.sha256(payload).hexdigest(),
    'upstream_config_source': 'https://github.com/blender/blender/blob/main/release/datafiles/colormanagement/config.ocio',
    'attribution': ['Troy Sobotka', 'Zijun Eary Zhou', 'Mark Faderbauer', 'Sakari Kapanen'],
    'distribution': 'Generated numerical output only; no upstream Blender/OCIO config, source code or LUT is copied into the app.',
    'license_note': 'Upstream AgX standalone license not verified; do not infer a license from the OpenColorIO engine or this project.'
}
(out / 'provenance.json').write_text(json.dumps(metadata, indent=2) + '\n')
print('PSILO_COLOR_LUT', json.dumps({'bytes': len(payload), 'sha256': metadata['sha256']}))
