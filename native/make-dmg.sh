#!/bin/bash
# Build Margin.app and pack it into build/Margin.dmg with an /Applications drop target.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$project_dir/build/Margin.app"
dmg="$project_dir/build/Margin.dmg"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist" 2>/dev/null || true)"

bash "$project_dir/native/build.sh" >/dev/null
[[ -x "$bundle/Contents/MacOS/Margin" ]] || { echo "make-dmg: build failed: $bundle" >&2; exit 1; }

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
ditto "$bundle" "$stage/Margin.app"
ln -s /Applications "$stage/Applications"

rm -f "$dmg"
hdiutil create -volname "Margin${version:+ $version}" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
hdiutil verify "$dmg" >/dev/null
echo "$dmg"
