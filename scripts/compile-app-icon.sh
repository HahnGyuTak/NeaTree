#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icon_source="$repo_root/assets/icons/AppIcon.icon"
output_dir="${1:-}"
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 && -n "$output_dir" ]] || fail "Usage: scripts/compile-app-icon.sh OUTPUT_DIRECTORY"
[[ "$(uname -s)" == Darwin ]] || fail "Icon compilation requires macOS and Xcode."
[[ -f "$icon_source/icon.json" ]] || fail "Missing Icon Composer source: $icon_source"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
for artifact in Assets.car AppIcon.icns icon-info.plist icon-assets.json; do
    [[ ! -e "$output_dir/$artifact" ]] || fail "Output already exists; choose an empty output directory: $output_dir/$artifact"
done
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$repo_root/packaging/Info.plist")"

# Compile the layered document directly. Assets.car keeps the system-rendered
# layers; actool also renders the ICNS needed by earlier supported macOS releases.
xcrun actool "$icon_source" \
    --compile "$output_dir" \
    --output-format human-readable-text --notices --warnings --errors \
    --output-partial-info-plist "$output_dir/icon-info.plist" \
    --app-icon AppIcon --standalone-icon-behavior all \
    --target-device mac --minimum-deployment-target "$minimum_os" \
    --platform macosx --skip-app-store-deployment

[[ -s "$output_dir/Assets.car" && -s "$output_dir/AppIcon.icns" ]] \
    || fail "Icon compiler did not produce both layered assets and the compatibility ICNS."
xcrun assetutil --info "$output_dir/Assets.car" > "$output_dir/icon-assets.json"
python3 - "$output_dir/icon-info.plist" "$output_dir/icon-assets.json" <<'PY'
import json, plistlib, sys
with open(sys.argv[1], 'rb') as stream:
    info = plistlib.load(stream)
if info.get('CFBundleIconName') != 'AppIcon' or info.get('CFBundleIconFile') not in ('AppIcon', 'AppIcon.icns'):
    raise SystemExit('Icon compiler returned unexpected app icon metadata.')
with open(sys.argv[2]) as stream:
    assets = json.load(stream)
stacks = [asset for asset in assets if asset.get('AssetType') == 'IconImageStack' and asset.get('Name') == 'AppIcon']
if not any(stack.get('LayerCount', 0) >= 2 for stack in stacks):
    raise SystemExit('AppIcon must retain multiple layers in the compiled asset catalog.')
PY
