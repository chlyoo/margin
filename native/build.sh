#!/bin/bash
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$native_dir")"
bundle="$project_dir/build/Margin.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" -framework AppKit -framework WebKit -framework Security -framework LocalAuthentication \
  "$native_dir/Core.swift" "$native_dir/Workspace.swift" "$native_dir/Agent.swift" "$native_dir/Format.swift" "$native_dir/Terminal.swift" "$native_dir/Studio.swift" "$native_dir/Review.swift" "$native_dir/Editor.swift" "$native_dir/Search.swift" \
  "$native_dir/Sheets.swift" "$native_dir/Application.swift" "$native_dir/Checks.swift" \
  -o "$bundle/Contents/MacOS/Margin"
cp "$native_dir/preview.html" "$native_dir/preview.js" "$native_dir/preview.css" "$bundle/Contents/Resources/"
mkdir -p "$bundle/Contents/Resources/fixtures"
cp "$native_dir/fixtures/agent-stream.jsonl" "$bundle/Contents/Resources/fixtures/"
cp "$native_dir/Margin.icns" "$bundle/Contents/Resources/Margin.icns"
cp "$project_dir/node_modules/marked/lib/marked.umd.js" "$bundle/Contents/Resources/marked.js"
cp "$project_dir/node_modules/dompurify/dist/purify.min.js" "$bundle/Contents/Resources/purify.js"
cp "$project_dir/node_modules/prismjs/prism.js" "$bundle/Contents/Resources/prism.js"
cp "$project_dir/node_modules/prismjs/themes/prism.css" "$bundle/Contents/Resources/prism.css"
mkdir -p "$bundle/Contents/Resources/Licenses"
cp "$project_dir/node_modules/marked/LICENSE" "$bundle/Contents/Resources/Licenses/marked.txt"
cp "$project_dir/node_modules/dompurify/LICENSE" "$bundle/Contents/Resources/Licenses/DOMPurify.txt"
cp "$project_dir/node_modules/dompurify/LICENSE-MPL" "$bundle/Contents/Resources/Licenses/DOMPurify-MPL.txt"
cp "$project_dir/node_modules/prismjs/LICENSE" "$bundle/Contents/Resources/Licenses/Prism.txt"
shasum -a 256 "$native_dir"/*.swift "$native_dir"/preview.* > "$bundle/Contents/Resources/source-sha256.txt"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Margin</string>
<key>CFBundleIconFile</key><string>Margin</string>
<key>CFBundleIdentifier</key><string>com.peterlyoo.Margin</string>
<key>CFBundleName</key><string>Margin</string>
<key>CFBundleDisplayName</key><string>Margin</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Margin — local Markdown editor</string>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Markdown document</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>NSDocumentClass</key><string>MarginDocument</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string><string>public.plain-text</string></array>
<key>CFBundleTypeExtensions</key><array><string>md</string><string>markdown</string><string>txt</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$bundle"
if [[ "${1:-}" == "--check" ]]; then
  "$bundle/Contents/MacOS/Margin" --check
else
  printf '%s\n' "$bundle"
fi
