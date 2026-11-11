"""Verify that a horn-only USDZ revision preserves Psilo's runtime contract.

Usage: python3 scripts/check-psilo-usdz-contract.py OLD.usdz NEW.usdz \
         --report /tmp/psilo-contract.json
Requires the macOS usdcat/usdchecker command-line tools.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile


def own_properties(stage):
    """Read each exported prim's own authored properties independent of order.

    This deliberately accepts only the same property text, apart from signed
    zero. Geometry arrays, bindings, material inputs and control transforms all
    participate. Full prim paths distinguish repeated shader names.
    """
    result = {}
    stack = []
    matches = list(re.finditer(r'(?m)^([ \t]*)def (\w+) "([^"]+)"', stage))
    for index, match in enumerate(matches):
        indent = len(match.group(1))
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, match.group(3)))
        path = '/'.join(item[1] for item in stack)
        if any(item[1] in ('Horn_L', 'Horn_R') for item in stack):
            continue
        end = matches[index + 1].start() if index + 1 < len(matches) else len(stage)
        properties = [re.sub(r'(?<![\w.])-0(?=[,\)\s])', '0', line.strip())
                      for line in stage[match.end():end].splitlines() if '=' in line]
        result[path] = {'kind': match.group(2), 'properties': properties}
    return result


def texture_hashes(path):
    with zipfile.ZipFile(path) as archive:
        return {Path(name).name: hashlib.sha256(archive.read(name)).hexdigest()
                for name in archive.namelist()
                if Path(name).suffix.lower() in ('.png', '.jpg', '.jpeg')}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('old', type=Path)
    parser.add_argument('new', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='psilo-contract-') as directory:
        stages = []
        for label, path in [('old', args.old), ('new', args.new)]:
            target = Path(directory) / (label + '.usda')
            subprocess.run(['usdcat', str(path), '-o', str(target)], check=True)
            stages.append(target.read_text())
    old, new = (own_properties(stage) for stage in stages)
    changed = [path for path, value in old.items() if new.get(path) != value]
    added = sorted(set(new) - set(old))
    assert not changed and not added, {'changed': changed, 'added': added}
    required = ['Psilo', 'Head', 'Horns', 'Hat', 'Glasses', 'eye_L', 'eye_R',
                'mouth_idle', 'mouth_proud', 'ErrorEyes', 'spiral_L', 'spiral_R',
                'file_0', 'file_1', 'file_2']
    xforms = {Path(path).name for path, prim in new.items() if prim['kind'] == 'Xform'}
    assert set(required) <= xforms
    assert 'upAxis = "Y"' in stages[1]
    assert 'STUDIO_' not in stages[1]
    assert texture_hashes(args.old) == texture_hashes(args.new)
    subprocess.run(['usdchecker', '--arkit', str(args.new)], check=True)
    report = {
        'checked_non_horn_prims': len(old),
        'checked_non_horn_xforms': len(xforms),
        'non_horn_geometry_materials_and_transforms_identical': True,
        'comparison_normalization': 'Signed zero canonicalized; prim sibling order ignored.',
        'required_rig_controls': required,
        'up_axis': 'Y',
        'materials': stages[1].count('info:id = "UsdPreviewSurface"'),
        'texture_sha256': texture_hashes(args.new),
        'original_usdz_sha256': hashlib.sha256(args.old.read_bytes()).hexdigest(),
        'updated_usdz_sha256': hashlib.sha256(args.new.read_bytes()).hexdigest(),
        'usdchecker_arkit': 'passed',
    }
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
