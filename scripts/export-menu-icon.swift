import AppKit

// Raster export only: preserve the approved generated glyph and its alpha mask.
// Trim transparent source margins so the artwork occupies an 18pt status item.
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("assets/icons/MenuBar-master.png")
let source = NSBitmapImageRep(data: try Data(contentsOf: sourceURL))!
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
for y in 0..<source.pixelsHigh {
    for x in 0..<source.pixelsWide where source.colorAt(x: x, y: y)!.alphaComponent > 0.01 {
        minX = min(minX, x); minY = min(minY, y)
        maxX = max(maxX, x); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY,
      let glyph = source.cgImage?.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
else { fatalError("Menu-bar master has no artwork") }
let output = root.appendingPathComponent("Sources/OrganizerApp/Resources", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (pixels, name) in [(18, "MenuBarTemplate.png"), (36, "MenuBarTemplate@2x.png")] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!.cgContext
    context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    context.interpolationQuality = .high
    let scale = CGFloat(pixels) / CGFloat(max(glyph.width, glyph.height))
    let width = CGFloat(glyph.width) * scale, height = CGFloat(glyph.height) * scale
    context.draw(glyph, in: CGRect(x: (CGFloat(pixels) - width) / 2, y: (CGFloat(pixels) - height) / 2, width: width, height: height))
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    print("Exported \(name): \(pixels)×\(pixels)")
}
