# Psilo hat correction — review v3

User feedback: “모자 잘못썼어”. This version corrects how the hat is worn,
following the original reference. Appearance remains unapproved.

- Backward pitch: −0.32 radians about the crown/brim seat.
- Left-low/right-high roll from the original sculpt is preserved.
- Seat height is raised 1 mm; right brim downward curl is reduced by 6 mm,
  exposing its inner surface.
- Band width is reduced to 72% and fitted to the crown surface.
- The crown's lower ring is seated inside the curved brim's actual thickness,
  avoiding both an open seam and a protruding inner edge.

`Psilo-v3-hat.blend` is neutral. `Psilo-v3-hat-motion.blend` retains the v2
12-second review timeline with the corrected hat as its neutral pose. The model
body, face, horns, props and their animation design are unchanged. The v2 video
shows the previous hat and is not the new version's motion preview.

Source: `../../../scripts/psilo-hat-fit-v3.py`. Load the v2 neutral source or
restore the v2 review rig with `psilo-motion-v2.py`, then call
`fit_psilo_hat_v3(scene)` before creating animation. The helper stores its v2
geometry baseline and is idempotent. It updates the hat's stored rest transform
so animation preserves the new fit.

All PNGs are actual Blender renders. The comparison sheet only places images
side by side. The existing app USDZ and the v2 review source are unchanged.
This hat correction has not yet been exported to the reduced runtime model.
