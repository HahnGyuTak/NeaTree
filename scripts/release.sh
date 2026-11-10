#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="${1:-}"
notes_file="${2:-}"
[[ -n "$package_dir" && -n "${GH_REPO:-}" ]] || {
    printf 'Usage: GH_REPO=owner/repo scripts/release.sh PACKAGE_DIR [NOTES_FILE]\n' >&2
    exit 1
}
package_dir="$(cd "$package_dir" && pwd)"
metadata="$package_dir/build-metadata.json"
[[ -f "$metadata" && -f "$package_dir/SHA256SUMS" ]] || { printf 'Missing build metadata.\n' >&2; exit 1; }

# Refuse development archives; this command always creates a draft, never publishes.
python3 - "$metadata" "$(git -C "$repo_root" rev-parse HEAD)" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1]))
assert data['notarized'] and data['signing_status'] == 'developer-id-notarized', 'Notarized Developer ID build required.'
assert data['configuration'] == 'release' and not data['source_dirty'], 'Clean release build required.'
assert data['source_commit'] == sys.argv[2], 'Checkout must match the packaged source commit.'
assert re.fullmatch(r'\d+\.\d+\.\d+', data['version']), 'Invalid version.'
for filename in data['artifacts']:
    assert re.fullmatch(r'[A-Za-z0-9._-]+\.(zip|dmg)', filename), 'Invalid artifact name.'
assert data['artifacts'], 'No release artifacts.'
PY
(
    cd "$package_dir"
    shasum -a 256 --check SHA256SUMS
)
app="$package_dir/NeaTree.app"
codesign --verify --deep --strict --verbose=2 "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$metadata")"
commit="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$metadata")"
tag="v$version"
if gh release view "$tag" --repo "$GH_REPO" >/dev/null 2>&1; then
    printf 'Release %s already exists; no existing release was changed.\n' "$tag" >&2
    exit 1
fi
existing_tag="$(gh api "repos/$GH_REPO/commits/$tag" --jq .sha 2>/dev/null || true)"
[[ -z "$existing_tag" || "$existing_tag" == "$commit" ]] || {
    printf 'Existing tag points to a different commit.\n' >&2
    exit 1
}

artifacts=()
while IFS= read -r filename; do artifacts+=("$package_dir/$filename"); done < <(
    python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["artifacts"]))' "$metadata"
)
artifacts+=("$metadata" "$package_dir/SHA256SUMS")
release_args=(release create "$tag" --repo "$GH_REPO" --target "$commit" --title "NeaTree $version" --draft)
if [[ "${RELEASE_PRERELEASE:-true}" == true ]]; then release_args+=(--prerelease); fi
if [[ -n "$notes_file" ]]; then
    [[ -f "$notes_file" ]] || { printf 'Release notes file is missing.\n' >&2; exit 1; }
    release_args+=(--notes-file "$notes_file")
else
    release_args+=(--generate-notes)
fi
gh "${release_args[@]}" "${artifacts[@]}"
printf 'Draft created. Review the downloads and release notes before publishing.\n'
