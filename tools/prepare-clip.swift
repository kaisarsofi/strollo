// Turns a green-screen video of a front-facing action (drink, stretch, ...) into transparent frames that loop.
//   ffmpeg -i character/drink.mp4 .build/df/f%04d.png
//   swiftc -O tools/prepare-clip.swift -o .build/prepare-clip
//   .build/prepare-clip .build/df character/sprites drink <still figure height px> <still canvas height px>
import AppKit

let args = CommandLine.arguments
let inDir = args[1], outDir = args[2], clip = args[3]
let stillFigure = Double(args[4])!, stillCanvas = Double(args[5])!
let fps = 24.0
/// `strict` clips (the hoverboard) have wind streaks and sparkles in the footage: drop faint stray bits, keep the board's glow.
let strict = args.count > 6 && args[6] == "strict"

struct Bitmap { var d: [UInt8]; let w: Int; let h: Int }

func load(_ path: String) -> Bitmap {
    let cg = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let w = cg.width, h = cg.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return Bitmap(d: buf, w: w, h: h)
}

func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

func key(_ bmp: inout Bitmap) {
    for i in stride(from: 0, to: bmp.w * bmp.h * 4, by: 4) {
        let r = Double(bmp.d[i]), g = Double(bmp.d[i + 1]), b = Double(bmp.d[i + 2])
        let e = g - max(r, b)
        // bright background green, plus anything strongly green for its brightness (the floor shadow).
        // The olive bandana is only mildly green on both measures, so it survives.
        let a = min(1 - smooth(50, 95, e), 1 - smooth(0.34, 0.5, e / max(g, 1)))
        let g2 = e > 35 ? max(r, b) + 35 * a : g
        bmp.d[i] = UInt8(r * a); bmp.d[i + 1] = UInt8(min(g2, 255) * a); bmp.d[i + 2] = UInt8(b * a)
        bmp.d[i + 3] = UInt8(a * 255)
    }
}

/// Clears the faint floor shadow some clips have. Only the strip around the feet is touched, and only
/// see-through pixels there, so the solid shoes stay and a translucent bottle higher up is never affected.
func clearFloorHaze(_ bmp: inout Bitmap) {
    let w = bmp.w, h = bmp.h
    var top = h, bottom = 0
    for y in 0..<h { for x in 0..<w where bmp.d[(y * w + x) * 4 + 3] > 200 { top = min(top, y); bottom = max(bottom, y) } }
    guard bottom > top else { return }
    let from = max(1, bottom - (bottom - top) * 14 / 100)
    var clear: [Int] = []
    for y in from..<(h - 1) { for x in 1..<(w - 1) {
        let p = y * w + x
        let a = bmp.d[p * 4 + 3]
        guard a > 0, a < 150 else { continue }
        // keep the one-pixel soft edge of something solid
        if bmp.d[(p - 1) * 4 + 3] >= 200 || bmp.d[(p + 1) * 4 + 3] >= 200 || bmp.d[(p - w) * 4 + 3] >= 200 || bmp.d[(p + w) * 4 + 3] >= 200 { continue }
        clear.append(p)
    } }
    for p in clear { bmp.d[p * 4] = 0; bmp.d[p * 4 + 1] = 0; bmp.d[p * 4 + 2] = 0; bmp.d[p * 4 + 3] = 0 }
}

/// Strict clips: keeps see-through pixels only when solid pixels are within a few pixels (the board's glow),
/// so wind streaks and sparkles floating nearby disappear.
func dropDetached(_ bmp: inout Bitmap, radius: Int = 5) {
    let w = bmp.w, h = bmp.h
    var solid = [UInt8](repeating: 0, count: w * h)
    for p in 0..<(w * h) where bmp.d[p * 4 + 3] >= 230 { solid[p] = 1 }
    var horiz = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
        var hit: UInt8 = 0
        for dx in -radius...radius { let nx = x + dx; if nx >= 0, nx < w, solid[y * w + nx] == 1 { hit = 1; break } }
        horiz[y * w + x] = hit
    } }
    for y in 0..<h { for x in 0..<w {
        let p = y * w + x
        guard bmp.d[p * 4 + 3] > 0, solid[p] == 0 else { continue }
        var near = false
        for dy in -radius...radius { let ny = y + dy; if ny >= 0, ny < h, horiz[ny * w + x] == 1 { near = true; break } }
        if !near { bmp.d[p * 4] = 0; bmp.d[p * 4 + 1] = 0; bmp.d[p * 4 + 2] = 0; bmp.d[p * 4 + 3] = 0 }
    } }
}

/// Takes the green tint off the outline: pixels within two of the edge lose their excess green.
func despillEdges(_ bmp: inout Bitmap) {
    let w = bmp.w, h = bmp.h
    var edge = [Bool](repeating: false, count: w * h)
    for y in 2..<(h - 2) { for x in 2..<(w - 2) where bmp.d[(y * w + x) * 4 + 3] > 0 {
        let p = y * w + x
        if bmp.d[(p - 1) * 4 + 3] < 30 || bmp.d[(p + 1) * 4 + 3] < 30 || bmp.d[(p - w) * 4 + 3] < 30 || bmp.d[(p + w) * 4 + 3] < 30
            || bmp.d[(p - 2) * 4 + 3] < 30 || bmp.d[(p + 2) * 4 + 3] < 30 || bmp.d[(p - 2 * w) * 4 + 3] < 30 || bmp.d[(p + 2 * w) * 4 + 3] < 30 {
            edge[p] = true
        }
    } }
    for p in 0..<(w * h) where edge[p] {
        let i = p * 4
        let cap = Int(max(bmp.d[i], bmp.d[i + 2])) + 6
        if Int(bmp.d[i + 1]) > cap { bmp.d[i + 1] = UInt8(cap) }
    }
}

/// Keeps the figure and anything it is holding. Connectivity uses a low alpha threshold so a see-through
/// bottle stays attached to the hand; watermark sparkles and specks elsewhere are dropped.
func keepLargest(_ bmp: inout Bitmap) {
    let w = bmp.w, h = bmp.h, thr: UInt8 = strict ? 70 : 12
    var label = [Int32](repeating: 0, count: w * h)
    var sizes: [Int] = [0]
    var stack: [Int] = []
    for start in 0..<(w * h) where label[start] == 0 && bmp.d[start * 4 + 3] > thr {
        let id = Int32(sizes.count)
        var size = 0
        stack.append(start); label[start] = id
        while let p = stack.popLast() {
            size += 1
            let x = p % w, y = p / w
            if x > 0, label[p - 1] == 0, bmp.d[(p - 1) * 4 + 3] > thr { label[p - 1] = id; stack.append(p - 1) }
            if x < w - 1, label[p + 1] == 0, bmp.d[(p + 1) * 4 + 3] > thr { label[p + 1] = id; stack.append(p + 1) }
            if y > 0, label[p - w] == 0, bmp.d[(p - w) * 4 + 3] > thr { label[p - w] = id; stack.append(p - w) }
            if y < h - 1, label[p + w] == 0, bmp.d[(p + w) * 4 + 3] > thr { label[p + w] = id; stack.append(p + w) }
        }
        sizes.append(size)
    }
    guard sizes.count > 1 else { return }
    let keep = Int32(sizes.indices.max { sizes[$0] < sizes[$1] }!)
    for p in 0..<(w * h) where label[p] != keep {
        bmp.d[p * 4] = 0; bmp.d[p * 4 + 1] = 0; bmp.d[p * 4 + 2] = 0; bmp.d[p * 4 + 3] = 0
    }
}

struct Frame {
    var bmp: Bitmap
    var minX = 0, maxX = 0, minY = 0, maxY = 0
    var feetX = 0.0
    var sig: [Float] = []
}

func measure(_ bmp: Bitmap) -> Frame {
    var f = Frame(bmp: bmp)
    var minX = bmp.w, maxX = 0, minY = bmp.h, maxY = 0
    for y in 0..<bmp.h { for x in 0..<bmp.w where bmp.d[(y * bmp.w + x) * 4 + 3] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    (f.minX, f.maxX, f.minY, f.maxY) = (minX, maxX, minY, maxY)
    var fx0 = bmp.w, fx1 = 0
    for y in (maxY - (maxY - minY) * 5 / 100)...maxY { for x in minX...maxX where bmp.d[(y * bmp.w + x) * 4 + 3] > 40 { fx0 = min(fx0, x); fx1 = max(fx1, x) } }
    f.feetX = Double(fx0 + fx1) / 2
    return f
}

func signature(_ f: Frame, cx: Double, height: Double, ground: Double) -> [Float] {
    let gw = 40, gh = 56
    var out = [Float](repeating: 0, count: gw * gh * 2)
    let x0 = cx - height * 0.6, y0 = ground - height * 1.05
    let cw = height * 1.2 / Double(gw), chh = height * 1.05 / Double(gh)
    for gy in 0..<gh { for gx in 0..<gw {
        var a = 0.0, l = 0.0, n = 0.0
        let xs = Int(x0 + Double(gx) * cw), ys = Int(y0 + Double(gy) * chh)
        for y in stride(from: ys, to: Int(Double(ys) + chh), by: 2) { for x in stride(from: xs, to: Int(Double(xs) + cw), by: 2) {
            n += 1
            guard x >= 0, x < f.bmp.w, y >= 0, y < f.bmp.h else { continue }
            let i = (y * f.bmp.w + x) * 4
            a += Double(f.bmp.d[i + 3]); l += Double(f.bmp.d[i]) + Double(f.bmp.d[i + 1]) + Double(f.bmp.d[i + 2])
        } }
        out[(gy * gw + gx) * 2] = Float(a / max(n, 1) / 255)
        out[(gy * gw + gx) * 2 + 1] = Float(l / max(n, 1) / 765)
    } }
    return out
}

func diff(_ a: [Float], _ b: [Float]) -> Double {
    var s: Float = 0
    for i in 0..<a.count { s += abs(a[i] - b[i]) }
    return Double(s) / Double(a.count)
}

let names = try! FileManager.default.contentsOfDirectory(atPath: inDir).filter { $0.hasSuffix(".png") }.sorted()
var frames: [Frame] = []
for n in names {
    var bmp = load(inDir + "/" + n)
    key(&bmp)
    if !strict { clearFloorHaze(&bmp) }
    if strict { dropDetached(&bmp) }
    keepLargest(&bmp)
    despillEdges(&bmp)
    frames.append(measure(bmp))
}
// the clip opens on the relaxed standing pose: that sets the character's height, feet position and ground line
let opening = Array(frames.prefix(12))
let height = opening.map { Double($0.maxY - $0.minY) }.sorted()[6]
let feetX = frames.map(\.feetX).sorted()[frames.count / 2]
let ground = frames.map { Double($0.maxY) }.sorted()[frames.count / 2]
for i in frames.indices { frames[i].sig = signature(frames[i], cx: feetX, height: height, ground: ground) }
print("\(frames.count) frames, character \(Int(height)) px tall, feet x \(Int(frames.map(\.feetX).min()!))...\(Int(frames.map(\.feetX).max()!)), ground y \(Int(frames.map { Double($0.maxY) }.min()!))...\(Int(frames.map { Double($0.maxY) }.max()!))")

// trim so the last frame flows back into the first: best match between an early frame and a late one
var a = 0, b = frames.count - 1, best = Double.infinity
for i in 0..<min(36, frames.count / 4) {
    for j in (frames.count - min(60, frames.count / 3))..<frames.count {
        let d = diff(frames[i].sig, frames[j].sig)
        if d < best { best = d; a = i; b = j }
    }
}
print("loop: frames \(a)..<\(b) (\(b - a) frames, \(String(format: "%.1f", Double(b - a) / fps)) s), seam difference \(String(format: "%.4f", best))")
let loop = Array(frames[a..<b])

// native video resolution; the canvas is sized so the character matches the still poses when drawn at the same height
let unit = height / stillFigure                     // video px per still px
let ch = Int((stillCanvas * unit).rounded()), pad = 8 * unit
var half = 0.0
for f in loop { half = max(half, feetX - Double(f.minX), Double(f.maxX) - feetX) }
let cw = Int(half * 2 + pad * 2)

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for old in (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? [] where old.hasPrefix(clip + "_") {
    try? FileManager.default.removeItem(atPath: outDir + "/" + old)
}
for (k, f) in loop.enumerated() {
    let src = f.bmp
    let provider = CGDataProvider(data: Data(src.d) as CFData)!
    let cg = CGImage(width: src.w, height: src.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: src.w * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .none
    let ox = (Double(cw) / 2 - feetX).rounded()
    let oy = (pad - (Double(src.h) - 1 - ground)).rounded()
    ctx.draw(cg, in: CGRect(x: ox, y: oy, width: Double(src.w), height: Double(src.h)))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + clip + String(format: "_%03d.png", k)))
}
// clips open with a second or two of standing still; note where the action really begins so the app can start near it
var lead = 0
for k in 1..<loop.count where diff(loop[k].sig, loop[0].sig) > max(0.012, best * 2.5) { lead = max(0, k - 10); break }
print("action begins around frame \(lead + 10); playback will start at frame \(lead)")
let json = String(format: "{\"clip\": true, \"frames\": %d, \"fps\": %.0f, \"start\": %d}", loop.count, fps, lead)
try! json.write(toFile: outDir + "/" + clip + ".json", atomically: true, encoding: .utf8)
print("wrote \(loop.count) frames, \(cw)x\(ch)")
