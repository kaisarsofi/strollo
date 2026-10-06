// Packs the prepared character frames for shipping: PNG -> HEIC (with transparency), JSON copied as is.
//   swiftc -O tools/pack-character.swift -o .build/pack-character
//   .build/pack-character character/sprites .build/character2 [quality 0...1]
import AppKit
import ImageIO

let args = CommandLine.arguments
let src = URL(fileURLWithPath: args[1]), dst = URL(fileURLWithPath: args[2])
let quality = args.count > 3 ? Double(args[3])! : 0.8
let fm = FileManager.default
try? fm.removeItem(at: dst)
try! fm.createDirectory(at: dst, withIntermediateDirectories: true)
let files = try! fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
for f in files where f.pathExtension == "json" {
    try! fm.copyItem(at: f, to: dst.appendingPathComponent(f.lastPathComponent))
}
let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
let failed = NSLock()
var failures: [String] = []
DispatchQueue.concurrentPerform(iterations: pngs.count) { i in
    let f = pngs[i]
    let out = dst.appendingPathComponent(f.deletingPathExtension().lastPathComponent + ".heic")
    guard let s = CGImageSourceCreateWithURL(f as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(s, 0, nil),
          let d = CGImageDestinationCreateWithURL(out as CFURL, "public.heic" as CFString, 1, nil) else {
        failed.lock(); failures.append(f.lastPathComponent); failed.unlock(); return
    }
    CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    if !CGImageDestinationFinalize(d) { failed.lock(); failures.append(f.lastPathComponent); failed.unlock() }
}
if !failures.isEmpty { print("FAILED: \(failures.prefix(5)) (\(failures.count))"); exit(1) }
print("packed \(pngs.count) images at quality \(quality)")
