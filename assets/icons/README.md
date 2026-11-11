# NeaTree icon sources

The approved reference is [icons-approved-v1.png](../../docs/design/icons-approved-v1.png).

- `AppIcon.icon`: editable Apple Icon Composer document. The native background, gardener and files are separate rendered layers. The foreground artwork keeps its paper colors; the system supplies the background material, appearance and external lighting.
- `AppIcon.icon/Assets/Character.png` and `Files.png`: transparent, aligned 1024px artwork layers generated from the approved reference.
- `MenuBar-master.png`: transparent mushroom-capped document silhouette. The page interior remains transparent so the template reads on both menu-bar appearances.
- `generation-prompts.json`: exact prompts used with the built-in image generator for these separated assets.

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
