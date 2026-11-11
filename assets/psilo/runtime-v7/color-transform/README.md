# Psilo display transform

NeaTree samples Blender's display rendering into a small 33³ table so the runtime preview retains the authoring scene's soft coral and cream appearance. The package contains generated numerical output; Blender, OpenColorIO, their source/configuration files, and upstream LUT files are not bundled.

Canonical app resource: `Sources/OrganizerApp/Resources/PsiloDisplayTransform.rgba16float`.

- 287,496 bytes; 33 × 33 × 33 × RGBA × 16 bits, little-endian IEEE754 half.
- SHA-256: `eaad6b75749f60e553f0df2ef37145eacf54fb3b006f15e5e4a00abb2bd00bb0`.
- Blender 5.3.0 build `02f0899d78e3`; AgX, Medium High Contrast, sRGB display, +0.4 exposure, gamma 1.
- Red/X varies fastest, followed by green/Y and blue/Z. Each axis samples `2^(-12 + 16u)` for `u` from 0 to 1.
- Output entries contain display-encoded sRGB. The runtime uses ICC-verified P3/Rec.709 conversion and decodes the sampled result to linear for recognized sRGB Metal targets or verified linear rgba16Float snapshot buffers. Unknown profiles or formats pass through.
- The runtime's additional +1.2 stops calibration multiplies the native linear frame color by 2.29739671 before the logarithmic lookup. It is separate from the LUT's baked +0.4 exposure.

The generator creates a float color grid, asks Blender `Image.save_render` to apply the actual display transform into a 16-bit PNG, reads those output values as Non-Color data, and converts them to half floats. It does not implement an approximation of AgX or copy an upstream color table. The intermediate PNG is deleted. `provenance.json` records the exact generator and Blender configuration input hashes.

From the repository root, choose a new empty output directory:

```sh
blender -b --python scripts/build-psilo-color-lut.py -- --out /tmp/psilo-color-lut
```

The generated half-float file was compared byte-for-byte with the bundled resource and matches. Different Blender builds/configurations must be checked against the recorded input hashes before claiming reproducibility.

See [NOTICE.md](NOTICE.md) for attribution and the bounded upstream license-status note.
