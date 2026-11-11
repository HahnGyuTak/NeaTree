# Psilo v5 — approved short horns

This Blender authoring version applies the short, softly pointed horns approved
in [the reference image](../reference/short-horns-approved-v1.png). Only the two
horn meshes changed from v4. The v4 cap, hat, markings, paper material, facial
controls and motion remain intact. Approval of the horns does not imply approval
of the full v4/v5 character or replacement of the app's existing body.

The horns have a straight centreline leaning outward by 8 degrees, a 32 mm axis,
an approximately 30 mm broad base, and a softly tapered tip. Each closed mesh
uses 738 control vertices and one subdivision level. The `Horns`, `Horn_L` and
`Horn_R` names remain compatible with the motion controls.

| File | Purpose |
| --- | --- |
| `Psilo-v5.blend` | Neutral editable source with packed textures. |
| `Psilo-v5-motion.blend` | Existing continuous 1–289 frame performance with the new horns. |
| `front.png`, `left.png`, `right.png` | Neutral front and 35-degree views. |
| `working.png` | Frame 88: glasses and file props in the working pose. |
| `proud.png` | Frame 141: proud completion pose. |
| `error.png`, `transition.png` | Frames 207 and 210: error and transition poses. |
| `horn-update-report.json` | Geometry closure, dimensions and change-scope checks. |

The separate app model in `../blender/` received only its horn replacement.
Its other 83 USD prims retain identical geometry, materials, transforms and
metadata. That runtime version uses 362 control vertices per horn and retains
the existing 6 materials and single 768×768 cap texture.

Regenerate this authoring candidate from the repository root, using an empty
output directory:

```sh
blender --background assets/psilo/review-v4-fit-surface/Psilo-v4.blend \
  --python scripts/build-psilo-short-horns-v5.py \
  -- --out /tmp/psilo-v5-review --kind review
```

For the app model, use `assets/psilo/blender/Psilo.blend` as the input and
`--kind runtime`. Validate the candidate before replacing the packaged USDZ.
The generator uses CPU Cycles for review images; the app continues to use its
lightweight USDZ and existing native motion driver.
