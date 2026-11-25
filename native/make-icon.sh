#!/usr/bin/env bash
# Regenerates native/Margin.icns from native/icon.svg. Run after editing the SVG; build.sh only copies the result.
set -euo pipefail
native_dir="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/Margin.iconset"
mkdir -p "$iconset"
cat > "$work/render.swift" <<'SWIFT'
import AppKit
let arguments = CommandLine.arguments
guard let image = NSImage(contentsOf: URL(fileURLWithPath: arguments[1])) else { fatalError("cannot read SVG") }
for (name, pixels) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]).appendingPathComponent("icon_\(name).png"))
}
SWIFT
xcrun swift "$work/render.swift" "$native_dir/icon.svg" "$iconset"
iconutil --convert icns --output "$native_dir/Margin.icns" "$iconset"
if [[ -n "${1:-}" ]]; then cp "$iconset/icon_512x512.png" "$1"; fi
printf '%s\n' "$native_dir/Margin.icns"
