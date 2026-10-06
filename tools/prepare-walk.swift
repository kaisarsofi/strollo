// Turns a green-screen walk-in-place video into a looping set of transparent walk frames.
//   ffmpeg -i character/walk.mp4 .build/vf/f%04d.png
//   swiftc -O tools/prepare-walk.swift -o .build/prepare-walk
//   .build/prepare-walk .build/vf character/sprites <still figure height px> <still canvas height px>
import AppKit

let args = CommandLine.arguments
let inDir = args[1], outDir = args[2]
let stillFigure = Double(args[3])!, stillCanvas = Double(args[4])!   // so walk frames match the still poses' size
let upscale = 2.0

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

func keepLargest(_ bmp: inout Bitmap) {
    let w = bmp.w, h = bmp.h
    var label = [Int32](repeating: 0, count: w * h)
    var sizes: [Int] = [0]
    var stack: [Int] = []
    for start in 0..<(w * h) where label[start] == 0 && bmp.d[start * 4 + 3] > 40 {
        let id = Int32(sizes.count)
        var size = 0
        stack.append(start); label[start] = id
        while let p = stack.popLast() {
            size += 1
            let x = p % w, y = p / w
            if x > 0, label[p - 1] == 0, bmp.d[(p - 1) * 4 + 3] > 40 { label[p - 1] = id; stack.append(p - 1) }
            if x < w - 1, label[p + 1] == 0, bmp.d[(p + 1) * 4 + 3] > 40 { label[p + 1] = id; stack.append(p + 1) }
            if y > 0, label[p - w] == 0, bmp.d[(p - w) * 4 + 3] > 40 { label[p - w] = id; stack.append(p - w) }
            if y < h - 1, label[p + w] == 0, bmp.d[(p + w) * 4 + 3] > 40 { label[p + w] = id; stack.append(p + w) }
        }
        sizes.append(size)
    }
    guard sizes.count > 1 else { return }
    let keep = Int32(sizes.indices.max { sizes[$0] < sizes[$1] }!)
    // clear everything that is not the figure, including faint specks (keep only fringe pixels touching it)
    for p in 0..<(w * h) where label[p] != keep {
        let x = p % w, y = p / w
        var near = false
        if bmp.d[p * 4 + 3] > 0 {
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1), (-2, 0), (2, 0), (0, -2), (0, 2)] {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < w, ny >= 0, ny < h, label[ny * w + nx] == keep { near = true; break }
            }
        }
        if !near { bmp.d[p * 4] = 0; bmp.d[p * 4 + 1] = 0; bmp.d[p * 4 + 2] = 0; bmp.d[p * 4 + 3] = 0 }
    }
}

struct Frame {
    var bmp: Bitmap
    var minX = 0, maxX = 0, minY = 0, maxY = 0
    var bodyX = 0.0        // centre of the head and torso
    var feetSpan = 0.0     // width of whatever touches the bottom of the figure
    var sig: [Float] = []
}

func measure(_ bmp: Bitmap) -> Frame {
    var f = Frame(bmp: bmp)
    var minX = bmp.w, maxX = 0, minY = bmp.h, maxY = 0
    for y in 0..<bmp.h { for x in 0..<bmp.w where bmp.d[(y * bmp.w + x) * 4 + 3] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    (f.minX, f.maxX, f.minY, f.maxY) = (minX, maxX, minY, maxY)
    let hgt = maxY - minY
    var sx = 0.0, n = 0.0
    for y in minY...(minY + hgt * 45 / 100) { for x in minX...maxX where bmp.d[(y * bmp.w + x) * 4 + 3] > 40 { sx += Double(x); n += 1 } }
    f.bodyX = sx / max(n, 1)
    var fx0 = bmp.w, fx1 = 0
    for y in (maxY - hgt * 9 / 100)...maxY { for x in minX...maxX where bmp.d[(y * bmp.w + x) * 4 + 3] > 40 { fx0 = min(fx0, x); fx1 = max(fx1, x) } }
    f.feetSpan = Double(fx1 - fx0)
    return f
}

/// Coarse picture of the pose (colour and coverage) in a window fixed to the body, for comparing frames.
func signature(_ f: Frame, height: Double, ground: Double) -> [Float] {
    let gw = 40, gh = 56
    var out = [Float](repeating: 0, count: gw * gh * 2)
    let x0 = f.bodyX - height * 0.6, y0 = ground - height * 1.05
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
    keepLargest(&bmp)
    despillEdges(&bmp)
    frames.append(measure(bmp))
}
let heights = frames.map { Double($0.maxY - $0.minY) }.sorted()
let height = heights[heights.count * 9 / 10]              // standing height of the character, px
let grounds = frames.map { Double($0.maxY) }.sorted()
let ground = grounds[grounds.count / 2]
for i in frames.indices { frames[i].sig = signature(frames[i], height: height, ground: ground) }
print("\(frames.count) frames, character about \(Int(height)) px tall, ground y about \(Int(ground))")
print("body x drifts from \(Int(frames.map(\.bodyX).min()!)) to \(Int(frames.map(\.bodyX).max()!))")

// how alike are frames L apart? minima are the step period and the stride period
var score: [Int: Double] = [:]
for L in 8...70 {
    var s = 0.0, n = 0.0
    for i in stride(from: 10, to: frames.count - L, by: 2) { s += diff(frames[i].sig, frames[i + L].sig); n += 1 }
    score[L] = s / n
}
print("similarity by gap:", (8...70).map { "\($0):" + String(format: "%.3f", score[$0]!) }.joined(separator: " "))
var minima: [Int] = []
for L in 10...68 where score[L]! < score[L - 1]! && score[L]! <= score[L + 1]! && score[L]! < score[L - 2]! && score[L]! <= score[L + 2]! { minima.append(L) }
print("local minima at gaps:", minima)

// the stride (two steps) is the strongest repeat; one step alone would swap the legs at the seam
let candidates = minima.filter { $0 >= 20 }
guard let L = candidates.min(by: { score[$0]! < score[$1]! }) ?? minima.first else { fatalError("no repeating walk found") }
// start where the loop closes most cleanly
var start = 10, best = Double.infinity
for i in 10..<(frames.count - L - 1) {
    let d = diff(frames[i].sig, frames[i + L].sig) + diff(frames[i + 1].sig, frames[i + L + 1].sig)
    if d < best { best = d; start = i }
}
print("stride is \(L) frames; using frames \(start)..<\(start + L) (seam difference \(String(format: "%.4f", best / 2)))")

let loop = Array(frames[start..<(start + L)])
let spans = loop.map(\.feetSpan)
let stepPx = spans.max()! - spans.min()!
let scale = stillFigure / height
// sideways drift over the loop is removed as a straight line, so the last frame lines up with the first
let x0 = frames[start].bodyX, x1 = frames[start + L].bodyX
let anchors = (0..<L).map { x0 + (x1 - x0) * Double($0) / Double(L) }
let loopGround = loop.map { Double($0.maxY) }.sorted()[L / 2]
var half = 0.0
for (k, f) in loop.enumerated() { half = max(half, anchors[k] - Double(f.minX), Double(f.maxX) - anchors[k]) }
let pad = 8.0
let cw = Int((half * 2) * scale + pad * 2), ch = Int(stillCanvas)

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for old in (try? FileManager.default.contentsOfDirectory(atPath: outDir)) ?? [] where old.hasPrefix("walk_") {
    try? FileManager.default.removeItem(atPath: outDir + "/" + old)
}
for (k, f) in loop.enumerated() {
    let src = f.bmp
    let provider = CGDataProvider(data: Data(src.d) as CFData)!
    let cg = CGImage(width: src.w, height: src.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: src.w * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // body anchor to the canvas centre, ground line `pad` above the bottom edge
    let ox = Double(cw) / 2 - anchors[k] * scale
    let oy = pad - (Double(src.h) - 1 - loopGround) * scale
    ctx.draw(cg, in: CGRect(x: ox, y: oy, width: Double(src.w) * scale, height: Double(src.h) * scale))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + String(format: "/walk_%03d.png", k)))
}
// how far the body should travel per stride for the planted foot to stay put, in the app's 230pt-tall character space
// Measured from the planted foot: on a treadmill it slides back at walking speed, so the typical backwards
// shift of the sole between frames, times the frames in a stride, is the ground one stride should cover.
func sole(_ f: Frame) -> (lo: Int, hi: Int) {
    var lo = f.bmp.w, hi = 0
    for y in (f.maxY - 8)...f.maxY { for x in f.minX...f.maxX where f.bmp.d[(y * f.bmp.w + x) * 4 + 3] > 60 { lo = min(lo, x); hi = max(hi, x) } }
    return (lo, hi)
}
var slides: [Double] = []
for k in 1..<L {
    let a = sole(loop[k - 1]), b = sole(loop[k])
    let drift = anchors[k] - anchors[k - 1]
    for d in [Double(b.lo - a.lo) - drift, Double(b.hi - a.hi) - drift] where d < -4 && d > -30 { slides.append(-d) }
}
slides.sort()
let slide = slides.isEmpty ? 2 * stepPx / Double(L) : slides[slides.count / 2]
print("planted foot slides back about \(String(format: "%.1f", slide)) px per frame (from \(slides.count) samples); step-span estimate would be \(String(format: "%.1f", 2 * stepPx / Double(L)))")
let stridePts = slide * Double(L) * scale * 230 / stillCanvas
let json = String(format: "{\"frames\": %d, \"stride\": %.1f, \"fps\": 24}", L, stridePts)
try! json.write(toFile: outDir + "/walk.json", atomically: true, encoding: .utf8)
print("feet span \(Int(spans.min()!))...\(Int(spans.max()!)) px, so one step is about \(Int(stepPx)) px")
print("wrote \(L) frames, \(cw)x\(ch), stride \(String(format: "%.1f", stridePts)) pt")
