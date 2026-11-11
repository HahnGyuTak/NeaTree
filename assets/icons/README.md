# NeaTree icon sources

The approved reference is [icons-approved-v1.png](../../docs/design/icons-approved-v1.png).
The current horn shape was approved on 2026-11-12 in the [v7 Blender front](../psilo/review-v7-plump-horns/front.png) and [side](../psilo/review-v7-plump-horns/left.png): short, plump circular cones, broader rounded tips and a tilt matching the cap surface. The user explicitly requested the same shape in both icons. This supersedes the earlier [short horn reference](../psilo/reference/short-horns-approved-v1.png).

- `AppIcon.icon`: editable Apple Icon Composer document. The native background, gardener and files are separate rendered layers. The foreground artwork keeps its paper colors; the system supplies the background material, appearance and external lighting.
- `AppIcon.icon/Assets/Character.png` and `Files.png`: transparent, aligned 1024px artwork layers generated from the approved reference.
- `MenuBar-master.png`: transparent mushroom-capped document silhouette. The page interior remains transparent so the template reads on both menu-bar appearances.
- `generation-prompts.json`: exact prompts used with the built-in image generator for these separated assets.
- `app-icon-v7-horns-generation.json`, `menu-v7-horns-generation.json`: exact built-in image-generation edit prompts, source hashes and selected output records. These raster edits preserve the composition visually, not pixel-for-pixel outside the horns.
- `app-icon-v7-horns-verification.json`, `menu-v7-horns-verification.json`: native three-layer compilation, transparency and menu template export checks. See the [v7 change record](../../docs/design/v7-horns-icons.md) and its light/dark previews. Earlier `short-horns` records remain historical.

Export the 18pt menu glyph at 1× and 2× on macOS:

```sh
swift scripts/export-menu-icon.swift .
```

Compile the layered app icon with Xcode installed:

```sh
scripts/compile-app-icon.sh work/icon-compiled
cp work/icon-compiled/AppIcon.icns Sources/OrganizerApp/Resources/AppIcon.icns
```

Use a new output directory for each compile. The copied ICNS supports bare `swift run` development. Packaged apps compile the `.icon` themselves and include both `Assets.car` and the compiler-generated compatibility ICNS; the flat preview is never used as the layered source. See [distribution](../../docs/DISTRIBUTION.md).
