# Psilo Blender quality review v2

**Awaiting the user's visual approval.** These are editable Blender review
assets. The app's existing `Resources/Psilo.usdz` is unchanged. Appearance approval
and actual RealityKit verification are separate milestones.

The original Psilo portrait and action references define the character identity:
wide coral cap, three ivory spots, large blunt cashew-shaped horns, a gardener
hat with an olive band, tiny bead eyes, open oval mouth and a short cream body.
No human limbs have been added. The image sheets and video are actual Blender
renders; the comparison only places the supplied original beside a rendered view.

## Review files

- `Psilo-v2.blend`: neutral authoring model, packed color texture, materials,
  named controls, camera and simple studio lighting.
- `Psilo-v2-motion.blend`: the same model with a 12-second, 24fps review timeline.
- `reference-comparison.jpg`: supplied original and front render at equal width.
- `angles-and-poses.jpg`: front, left/right 30°, work, pride and error.
- `angle-side.png`: additional 65° inspection.
- `motion-review.mp4`: 289 frames including both timeline endpoints (12.042s).
- `runtime-review/`: separate reduced mesh and same-studio comparison source.
  Its JSON records the measured triangle count and retained morph targets.

The sequence demonstrates curious cursor attention; staggered file arrival;
glasses settling onto the face; reading and scanning; two proud gestures;
a second task; persistent spinning error eyes; and recovery to neutral.
The camera has extra room for incoming and departing files.

## Model and transition refinements

The authoring work used Blender MCP for live scene edits and rendering, with
`bpy` helpers for reproducibility. Refinements include horn cross sections,
hat crown/brim contact and curl, an asymmetric rolled cap lip, facial proportions,
warm materials, fine paper grain, a recessed mouth and staged accessory paths.

The cap uses a continuous quad surface with `SmileClose`, replacing the earlier
boolean/cover-patch expression. Each bead eye has a `Happy` shape key so it becomes
a closed smiling eye without swapping objects. Error spirals and glasses remain
separate named controls. Expression transitions were checked at intermediate
frames, including 141, 145, 151 and 157; discovered missing-eye and surface defects
were corrected before regenerating the review sequence.

The timeline uses predefined paths and eased transforms, without cloth, fluid or
rigid-body simulation. It is a motion specification, not a replacement for the
app's interruptible, state-driven spring animation.

## Reproduction

The helpers live in `../../../scripts/`:

1. `build-psilo-review-v2.py` builds into a new output directory without rendering.
2. `blender-psilo-v2.py` defines the base geometry, texture and studio.
3. `psilo-sculpt-refinement-v2.py` applies the current sculpt/material refinements.
4. `psilo-motion-v2.py` creates the review timeline and restores the neutral rig.
5. `render-psilo-review-v2.py` renders `angles`, `poses`, `motion` or `all`.
6. `psilo-runtime-lod.py` creates a separate reduced model; it never replaces the
   source or the app resource.

Example, with Blender available on PATH:

```sh
blender --background --python scripts/build-psilo-review-v2.py -- /new/review-folder
blender --background /new/review-folder/Psilo-v2-motion.blend --python scripts/render-psilo-review-v2.py -- all
```

An isolated build/restore/animation check verified required shape keys, neutral
restoration, bounded expression weights and finite transforms through all 289
frames. This is structural verification, not a claim of visual approval.

## Lightweight model and remaining app work

The authoring geometry retains subdivision for close-up review. The separate
reduced mesh targets about 40,000 triangles, keeps named controls and preserves
`Cap.SmileClose` plus both eye `Happy` shapes. Same-camera front/angled/proud
renders accompany it. Triangle count alone is not a performance measurement.

Before replacing the app asset, bake the procedural grain to compact textures,
export the runtime format, connect the new shape controls and compare the actual
RealityKit render and interrupted transitions with approved views. The current
Blender studio lighting does not establish app-renderer parity. Retain Reduce
Motion support and rendering teardown when hidden, minimized or occluded.

The user must explicitly approve the appearance and motion before this review
version is treated as final. No final approval is recorded here.
