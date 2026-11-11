# Color-transform provenance and attribution

The numerical output was generated using Blender's AgX view transform. Blender's [color-management configuration header](https://github.com/blender/blender/blob/main/release/datafiles/colormanagement/config.ocio) credits original AgX to Troy Sobotka, with further development by Zijun Eary Zhou, Mark Faderbauer, and Sakari Kapanen.

Primary upstream references:

- [Blender color-management configuration](https://github.com/blender/blender/blob/main/release/datafiles/colormanagement/config.ocio)
- [Original AgX](https://github.com/sobotka/AgX)
- [AgX version referenced by Blender](https://github.com/EaryChow/AgX)

NeaTree ships a generated numerical output table and its own generator, not the upstream configuration, LUT files, Blender binary, or OpenColorIO library. This notice preserves provenance and does not claim authorship of AgX.

A standalone license for the upstream AgX configuration/transform was not verified from these primary sources on 2026-11-12. The configuration refers to `ocio-license.txt`, which was absent from the inspected Blender distribution and current repository location. Consequently this record does not label AgX or the derived numerical table MIT, BSD, public domain, or otherwise infer terms from the separate OpenColorIO software library. This is an explicit limit of the provenance review, not a new license grant.
