// Draws the app icon (the character's portrait on a rounded blue tile) and writes a macOS .iconset folder.
//   swiftc -O tools/make-icon.swift -o .build/make-icon
//   .build/make-icon character/sprites/idle.png .build/AppIcon.iconset && iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
import AppKit

let args = CommandLine.arguments
let portrait = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let outDir = args[2]

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: s, y: s)
    // Apple's icon grid: an 824pt rounded tile centred in the 1024pt canvas, with a soft drop shadow
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor(red: 0.3, green: 0.5, blue: 0.95, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let colors = [NSColor(red: 0.52, green: 0.8, blue: 1, alpha: 1).cgColor, NSColor(red: 0.27, green: 0.42, blue: 0.95, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    // a soft glow behind the head
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [NSColor.white.withAlphaComponent(0.35).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])

    // head and shoulders: the top of the standing pose, enlarged, running off the bottom of the tile
    let pw = CGFloat(portrait.width), ph = CGFloat(portrait.height)
    let zoom: CGFloat = 1.72
    let w = pw * zoom, h = ph * zoom
    let top = tile.maxY - 40                       // bandana sits a little below the tile's top edge
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 22 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.draw(portrait, in: CGRect(x: 512 - w / 2, y: top - h + 31 * zoom, width: w, height: h))
    ctx.restoreGState()

    // thin light rim so the tile reads on dark backgrounds
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor); ctx.setLineWidth(4); ctx.strokePath()
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(atPath: outDir)
try! FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("wrote \(outDir)")
