#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="0.1.0"
build_number="1"
configuration="release"
architecture="native"
output_dir="$repo_root/dist"
scratch_path="$repo_root/.build/package"
binary_path=""
make_dmg=true
notarize=false
disable_manifest_sandbox=false
signing_identity="${SIGNING_IDENTITY:--}"
signing_keychain="${SIGNING_KEYCHAIN_PATH:-}"
notary_profile="${NOTARY_PROFILE:-}"
notary_keychain="${NOTARY_KEYCHAIN_PATH:-}"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: scripts/pack-app.sh [options]
  --version X.Y.Z                  App version (default 0.1.0)
  --build-number NUMBER             Bundle build number (default 1)
  --configuration debug|release     Default release
  --arch native|arm64|x86_64|universal
  --output-dir PATH                 New artifacts go here (default dist)
  --scratch-path PATH               SwiftPM and staging files
  --binary PATH                     Package an already-built executable
  --no-dmg                          Make APP and ZIP only
  --disable-manifest-sandbox        For an already sandboxed development shell
  --notarize                        Require Developer ID, notarize and staple

SIGNING_IDENTITY defaults to '-' (local ad-hoc development build).
For notarization, set a Developer ID Application identity and NOTARY_PROFILE.
Optional: SIGNING_KEYCHAIN_PATH and NOTARY_KEYCHAIN_PATH.
Existing same-version artifacts are never overwritten.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--build-number|--configuration|--arch|--output-dir|--scratch-path|--binary)
            [[ $# -ge 2 && -n "$2" ]] || fail "Missing value for $1"
            case "$1" in
                --version) version="$2" ;;
                --build-number) build_number="$2" ;;
                --configuration) configuration="$2" ;;
                --arch) architecture="$2" ;;
                --output-dir) output_dir="$2" ;;
                --scratch-path) scratch_path="$2" ;;
                --binary) binary_path="$2" ;;
            esac
            shift 2 ;;
        --no-dmg) make_dmg=false; shift ;;
        --notarize) notarize=true; shift ;;
        --disable-manifest-sandbox) disable_manifest_sandbox=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[[ "$(uname -s)" == Darwin ]] || fail "Packaging requires macOS."
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Use a numeric X.Y.Z version."
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "Build number must be a positive integer."
[[ "$configuration" == debug || "$configuration" == release ]] || fail "Invalid configuration."
case "$architecture" in native|arm64|x86_64|universal) ;; *) fail "Invalid architecture." ;; esac

source_commit="$(git -C "$repo_root" rev-parse HEAD)"
source_dirty=false
if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal)" ]]; then source_dirty=true; fi
if $notarize; then
    [[ "$signing_identity" == 'Developer ID Application:'* ]] || fail "Notarization requires a Developer ID Application identity."
    [[ -n "$notary_profile" ]] || fail "Set NOTARY_PROFILE to a notarytool keychain profile."
    [[ "$configuration" == release ]] || fail "Notarized packages must use release configuration."
    [[ "$source_dirty" == false ]] || fail "Commit all source changes before notarizing a release."
fi

mkdir -p "$output_dir" "$scratch_path"
output_dir="$(cd "$output_dir" && pwd)"
scratch_path="$(cd "$scratch_path" && pwd)"
staging="$(mktemp -d "$scratch_path/pack.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

swift_args=(--package-path "$repo_root" --configuration "$configuration" --scratch-path "$scratch_path/swift"
    --cache-path "$scratch_path/cache" --config-path "$scratch_path/config" --security-path "$scratch_path/security")
if $disable_manifest_sandbox; then swift_args+=(--disable-sandbox); fi
case "$architecture" in
    arm64|x86_64) swift_args+=(--arch "$architecture") ;;
    universal) swift_args+=(--arch arm64 --arch x86_64) ;;
esac
if [[ -z "$binary_path" ]]; then
    sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
    [[ "${sdk_version%%.*}" -ge 26 ]] || fail "Xcode 26 or newer is required to compile Liquid Glass APIs."
    mkdir -p "$scratch_path/module-cache"
    export CLANG_MODULE_CACHE_PATH="$scratch_path/module-cache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_path/module-cache"
    swift build "${swift_args[@]}" --product file-organizer \
        -Xswiftc -debug-prefix-map -Xswiftc "$repo_root=/src/NeaTree" \
        -Xswiftc -file-prefix-map -Xswiftc "$repo_root=/src/NeaTree"
    binary_dir="$(swift build "${swift_args[@]}" --show-bin-path)"
    binary_path="$binary_dir/file-organizer"
fi
[[ -f "$binary_path" && -x "$binary_path" ]] || fail "Executable not found: $binary_path"
binary_arches="$(lipo -archs "$binary_path")"
case "$architecture" in
    universal)
        [[ " $binary_arches " == *' arm64 '* && " $binary_arches " == *' x86_64 '* ]] || fail "Expected a universal executable." ;;
    arm64|x86_64)
        [[ " $binary_arches " == *" $architecture "* ]] || fail "Executable does not contain $architecture." ;;
esac
if [[ " $binary_arches " == *' arm64 '* && " $binary_arches " == *' x86_64 '* ]]; then
    artifact_arch=universal
elif [[ "$binary_arches" == arm64 || "$binary_arches" == x86_64 ]]; then
    artifact_arch="$binary_arches"
else
    fail "Unsupported executable architectures: $binary_arches"
fi

signing_status="ad-hoc-development"
suffix="-development"
if [[ "$signing_identity" != - ]]; then signing_status="signed-unnotarized"; suffix="-unnotarized"; fi
if $notarize; then signing_status="developer-id-notarized"; suffix=""; fi
artifact_name="NeaTree-$version-b$build_number-macos-$artifact_arch$suffix"
package_dir="$output_dir/$artifact_name"
[[ ! -e "$package_dir" ]] || fail "Output already exists; choose a new build number or output directory: $package_dir"
app="$staging/NeaTree.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$binary_path" "$app/Contents/MacOS/file-organizer"
cp "$repo_root/packaging/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null

codesign_args=(--force --sign "$signing_identity")
if [[ -n "$signing_keychain" ]]; then codesign_args+=(--keychain "$signing_keychain"); fi
if [[ "$signing_identity" == - ]]; then
    codesign_args+=(--timestamp=none)
else
    codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

notary_args=()
if $notarize; then
    notary_args=(--keychain-profile "$notary_profile")
    if [[ -n "$notary_keychain" ]]; then notary_args+=(--keychain "$notary_keychain"); fi
    codesign -dv --verbose=4 "$app" 2>&1 | /usr/bin/grep '^Authority=Developer ID Application:' >/dev/null \
        || fail "The signed app does not have a Developer ID Application authority."
    ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/notary-upload.zip"
    xcrun notarytool submit "$staging/notary-upload.zip" "${notary_args[@]}" --wait --output-format json > "$staging/notary-app.json"
    python3 - "$staging/notary-app.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('App notarization was not accepted: ' + str(result.get('status')))
PY
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi

# ZIP only after stapling: the downloadable ZIP must contain the final app.
ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/$artifact_name.zip"
artifacts=("$artifact_name.zip")
if $make_dmg; then
    mkdir -p "$staging/dmg-root"
    ditto "$app" "$staging/dmg-root/NeaTree.app"
    ln -s /Applications "$staging/dmg-root/Applications"
    hdiutil create -volname "NeaTree" -srcfolder "$staging/dmg-root" \
        -format UDZO -ov "$staging/$artifact_name.dmg" >/dev/null
    if $notarize; then
        dmg_sign_args=(--force --sign "$signing_identity" --timestamp)
        if [[ -n "$signing_keychain" ]]; then dmg_sign_args+=(--keychain "$signing_keychain"); fi
        codesign "${dmg_sign_args[@]}" "$staging/$artifact_name.dmg"
        xcrun notarytool submit "$staging/$artifact_name.dmg" "${notary_args[@]}" --wait --output-format json > "$staging/notary-dmg.json"
        python3 - "$staging/notary-dmg.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('status') != 'Accepted':
    raise SystemExit('DMG notarization was not accepted: ' + str(result.get('status')))
PY
        xcrun stapler staple "$staging/$artifact_name.dmg"
        xcrun stapler validate "$staging/$artifact_name.dmg"
    fi
    artifacts+=("$artifact_name.dmg")
fi

python3 - "$staging/build-metadata.json" "$version" "$build_number" "$configuration" "$binary_arches" \
    "$signing_status" "$notarize" "$source_commit" "$source_dirty" "${artifacts[@]}" <<'PY'
import json, sys
path, version, build, config, arches, signing, notarized, commit, dirty, *files = sys.argv[1:]
record = dict(version=version, build_number=build, configuration=config, architectures=arches.split(),
              signing_status=signing, notarized=notarized == 'true', source_commit=commit,
              source_dirty=dirty == 'true', artifacts=files)
with open(path, 'w') as stream:
    json.dump(record, stream, indent=2)
    stream.write('\n')
PY
(
    cd "$staging"
    shasum -a 256 "${artifacts[@]}" build-metadata.json > SHA256SUMS
)
mkdir "$package_dir"
ditto "$app" "$package_dir/NeaTree.app"
for artifact in "${artifacts[@]}" build-metadata.json SHA256SUMS; do
    cp "$staging/$artifact" "$package_dir/$artifact"
done
printf 'Package: %s\nSigning: %s\n' "$package_dir" "$signing_status"
