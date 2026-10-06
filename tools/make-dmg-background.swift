import AppKit
// DMG window background: soft gradient, a title, and an arrow from the app towards Applications.
let W = 660, H = 400
let ctx = CGContext(data: nil, width: W * 2, height: H * 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.scaleBy(x: 2, y: 2)
let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [NSColor(red: 0.9, green: 0.94, blue: 1, alpha: 1).cgColor, NSColor(red: 0.76, green: 0.84, blue: 0.98, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: CGFloat(W), y: 0), options: [])
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
let title = NSAttributedString(string: "Drag Strollo to Applications", attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor(red: 0.15, green: 0.22, blue: 0.45, alpha: 1)])
title.draw(at: NSPoint(x: (CGFloat(W) - title.size().width) / 2, y: 330))
let sub = NSAttributedString(string: "If macOS blocks it: System Settings > Privacy & Security > Open Anyway", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(red: 0.3, green: 0.38, blue: 0.6, alpha: 1)])
sub.draw(at: NSPoint(x: (CGFloat(W) - sub.size().width) / 2, y: 304))
NSGraphicsContext.restoreGraphicsState()
// arrow
ctx.setStrokeColor(NSColor(red: 0.3, green: 0.45, blue: 0.9, alpha: 0.9).cgColor); ctx.setLineWidth(6); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 270, y: 215)); ctx.addLine(to: CGPoint(x: 385, y: 215)); ctx.strokePath()
ctx.move(to: CGPoint(x: 362, y: 237)); ctx.addLine(to: CGPoint(x: 388, y: 215)); ctx.addLine(to: CGPoint(x: 362, y: 193)); ctx.strokePath()
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
