// Turns green-screen pose images into transparent, aligned sprites.
//   swiftc -O tools/prepare-character.swift -o .build/prepare-character
//   .build/prepare-character character character/sprites
import AppKit

let args = CommandLine.arguments
let inDir = args[1], outDir = args[2]
let outScale = 0.5          // source images are 2048px; half is plenty on a retina screen

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

/// Chroma key on "green excess" (g - max(r, b)). The background sits above 105; the olive bandana stays below 45.
func key(_ bmp: inout Bitmap) {
    let w = bmp.w, h = bmp.h
    for y in 0..<h {
        for x in 0..<w {
            let i = (y * w + x) * 4
            // the generator's sparkle watermark lives in the bottom-right corner
            if x > Int(Double(w) * 0.82) && y > Int(Double(h) * 0.82) {
                bmp.d[i] = 0; bmp.d[i + 1] = 0; bmp.d[i + 2] = 0; bmp.d[i + 3] = 0
                continue
            }
            let r = Double(bmp.d[i]), g = Double(bmp.d[i + 1]), b = Double(bmp.d[i + 2])
            let e = g - max(r, b)
            let a = 1 - smooth(55, 100, e)
            // despill: pull leftover green fringe back towards neutral
            let g2 = e > 40 ? max(r, b) + 40 * a : g
            bmp.d[i] = UInt8(r * a); bmp.d[i + 1] = UInt8(min(g2, 255) * a); bmp.d[i + 2] = UInt8(b * a)
            bmp.d[i + 3] = UInt8(a * 255)
        }
    }
}

/// Removes a grey bar the character is holding on to (the "hang" pose): rows that are mostly grey lose their grey pixels.
func removeBar(_ bmp: inout Bitmap) {
    let w = bmp.w
    func grey(_ i: Int) -> Bool {
        guard bmp.d[i + 3] > 40 else { return false }
        let r = Int(bmp.d[i]), g = Int(bmp.d[i + 1]), b = Int(bmp.d[i + 2])
        return max(r, g, b) - min(r, g, b) < 30
    }
    var barRows: [Int] = []
    for y in 0..<(bmp.h / 4) {
        var n = 0
        for x in 0..<w where grey((y * w + x) * 4) { n += 1 }
        if n > w / 2 { barRows.append(y) }
    }
    guard let first = barRows.first, let last = barRows.last else { return }
    // the bar's lit and shaded edges are tinted by the green screen, so within its band keep only the
    // hand (warm skin) and the sleeve (blue denim) and clear everything else
    for y in max(0, first - 45)...min(bmp.h - 1, last + 8) {
        for x in 0..<w {
            let i = (y * w + x) * 4
            guard bmp.d[i + 3] > 0 else { continue }
            let r = Int(bmp.d[i]), g = Int(bmp.d[i + 1]), b = Int(bmp.d[i + 2])
            let skin = r > g + 12 && r > b + 12
            let denim = b > r + 12 && b >= g
            if !skin && !denim { bmp.d[i] = 0; bmp.d[i + 1] = 0; bmp.d[i + 2] = 0; bmp.d[i + 3] = 0 }
        }
    }
    print("  removed a bar across rows \(first)...\(last)")
}

/// Keeps only the biggest connected shape, dropping stray bits (watermarks, floating artefacts).
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
    guard sizes.count > 2 else { return }
    let keep = Int32(sizes.indices.max { sizes[$0] < sizes[$1] }!)
    var dropped = 0
    for p in 0..<(w * h) where label[p] != keep && label[p] != 0 {
        // faint fringe pixels (label 0) next to the figure are left alone
        bmp.d[p * 4] = 0; bmp.d[p * 4 + 1] = 0; bmp.d[p * 4 + 2] = 0; bmp.d[p * 4 + 3] = 0
        dropped += 1
    }
    if dropped > 500 { print("  dropped \(sizes.count - 2) stray piece(s), \(dropped) px") }
}

struct Sprite { let name: String; let bmp: Bitmap; let minX: Int, maxX: Int, minY: Int, maxY: Int; let anchorX: Int; let top: Bool }

func measure(_ name: String, _ bmp: Bitmap, top: Bool = false) -> Sprite {
    var minX = bmp.w, maxX = 0, minY = bmp.h, maxY = 0
    for y in 0..<bmp.h { for x in 0..<bmp.w where bmp.d[(y * bmp.w + x) * 4 + 3] > 40 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    // anchor on the feet (the bottom 6% of the figure), or on the gripping hand (the top 4%) for a hanging pose
    let rows = top ? minY...(minY + (maxY - minY) * 4 / 100) : (maxY - (maxY - minY) * 6 / 100)...maxY
    var fx0 = bmp.w, fx1 = 0
    for y in rows { for x in 0..<bmp.w where bmp.d[(y * bmp.w + x) * 4 + 3] > 40 { fx0 = min(fx0, x); fx1 = max(fx1, x) } }
    return Sprite(name: name, bmp: bmp, minX: minX, maxX: maxX, minY: minY, maxY: maxY, anchorX: (fx0 + fx1) / 2, top: top)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let names = try! FileManager.default.contentsOfDirectory(atPath: inDir).filter { $0.hasSuffix(".png") }.sorted()
var sprites: [Sprite] = []
for n in names {
    var bmp = load(inDir + "/" + n)
    key(&bmp)
    let hanging = n.lowercased().hasPrefix("hang")
    print("\(n):")
    if hanging { removeBar(&bmp) }
    keepLargest(&bmp)
    let s = measure(n, bmp, top: hanging)
    print("  figure \(s.maxX - s.minX)x\(s.maxY - s.minY), anchor x=\(s.anchorX), \(hanging ? "top y=\(s.minY)" : "ground y=\(s.maxY)")")
    sprites.append(s)
}

// one canvas size for every pose, feet centred on the bottom edge, so swapping poses never shifts the character
let pad = 16
let half = sprites.map { max($0.anchorX - $0.minX, $0.maxX - $0.anchorX) }.max()! + pad
let tall = sprites.map { $0.maxY - $0.minY }.max()! + pad * 2
let cw = Int(Double(half * 2) * outScale), ch = Int(Double(tall) * outScale)
for s in sprites {
    let src = s.bmp
    let provider = CGDataProvider(data: Data(src.d) as CFData)!
    let cg = CGImage(width: src.w, height: src.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: src.w * 4,
                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    // place the source so its feet anchor lands at (canvas centre, pad from the bottom)
    let ox = Double(half - s.anchorX) * outScale
    // feet sit `pad` above the bottom edge; a hanging pose has its hand `pad/4` below the top edge instead
    let oy = s.top
        ? Double(ch) - Double(pad / 4) * outScale - Double(src.h - s.minY) * outScale
        : Double(pad) * outScale - Double(src.h - 1 - s.maxY) * outScale
    ctx.draw(cg, in: CGRect(x: ox, y: oy, width: Double(src.w) * outScale, height: Double(src.h) * outScale))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outDir + "/" + s.name))
}
print("wrote \(sprites.count) sprites, \(cw)x\(ch) each, to \(outDir)")
