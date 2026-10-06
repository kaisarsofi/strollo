import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Reminders

struct Reminder: Codable, Identifiable {
    var id = UUID()
    var message: String
    var intervalMinutes: Double
    var yesLabel: String = "Yes"
    var action: BuddyAction = .auto
    enum CodingKeys: String, CodingKey { case message, intervalMinutes, yesLabel, action }

    /// The animation to play: the chosen one, or a guess from the message when set to Auto.
    var resolvedAction: BuddyAction {
        if action != .auto { return action }
        let m = message.lowercased()
        if m.contains("water") || m.contains("drink") || m.contains("hydrat") { return .drink }
        if m.contains("stretch") || m.contains("back") || m.contains("posture") || m.contains("stand") { return .stretch }
        if m.contains("eye") || m.contains("screen") || m.contains("blink") { return .eyes }
        return .wave
    }
}

extension Reminder {
    // older reminders.json files have no "action" / "yesLabel" keys
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        message = try c.decode(String.self, forKey: .message)
        intervalMinutes = try c.decode(Double.self, forKey: .intervalMinutes)
        yesLabel = try c.decodeIfPresent(String.self, forKey: .yesLabel) ?? "Yes"
        action = (try? c.decodeIfPresent(BuddyAction.self, forKey: .action)) ?? .auto
    }
}

enum BuddyAction: String, Codable, CaseIterable, Identifiable {
    case auto, drink, stretch, eyes, wave
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto"
        case .drink: return "Drink water"
        case .stretch: return "Stretch"
        case .eyes: return "Rest eyes"
        case .wave: return "Wave"
        }
    }
}

/// The app used to be called PixelFriend. On first launch under the new name, bring the old reminders and
/// preferences across so nothing is lost.
enum Migration {
    static func run() {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let old = support.appendingPathComponent("PixelFriend"), new = support.appendingPathComponent("Strollo")
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            try? fm.copyItem(at: old, to: new)
        }
        let d = UserDefaults.standard
        if !d.bool(forKey: "migratedFromPixelFriend") {
            d.set(true, forKey: "migratedFromPixelFriend")
            if let before = UserDefaults(suiteName: "com.pixelfriend.app")?.persistentDomain(forName: "com.pixelfriend.app") {
                for (k, v) in before where d.object(forKey: k) == nil { d.set(v, forKey: k) }
            }
        }
    }
}

enum Store {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Strollo")
    static let file = dir.appendingPathComponent("reminders.json")

    static func save(_ list: [Reminder]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(list).write(to: file)
    }

    static func load() -> [Reminder] {
        if let data = try? Data(contentsOf: file),
           let list = try? JSONDecoder().decode([Reminder].self, from: data) {
            return list
        }
        let defaults = [
            Reminder(message: "Did you drink water?", intervalMinutes: 45),
            Reminder(message: "Time to stretch your back!", intervalMinutes: 60, yesLabel: "Done"),
            Reminder(message: "Rest your eyes for 20 seconds", intervalMinutes: 20, yesLabel: "Done"),
        ]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        try? enc.encode(defaults).write(to: file)
        return defaults
    }
}

// MARK: - Character UI

final class WalkModel: ObservableObject {
    @Published var message = ""
    @Published var yesLabel = "Yes"
    @Published var walking = true
    @Published var showBubble = false
    @Published var action: BuddyAction = .wave
    @Published var stoppedAt = Date()
    @Published var facingLeft = false
    @Published var peeking = false      // peek entrance instead of walking
    @Published var corner = "bottomRight"
    // Peek slide, driven by time so every frame lands exactly on the curve.
    var peekStart = Date()
    var peekIn = true

    /// 0 = hidden, 1 = fully peeking. Coming in is a soft spring that overshoots a touch; leaving eases away.
    func peekProgress(at date: Date) -> Double {
        let t = max(0, date.timeIntervalSince(peekStart))
        if peekIn {
            let w = 8.5, z = 0.74                       // spring frequency and damping
            let wd = w * (1 - z * z).squareRoot()
            return 1 - exp(-z * w * t) * (cos(wd * t) + z * w / wd * sin(wd * t))
        }
        let u = min(t / 0.42, 1)
        return 1 - u * u * (3 - 2 * u) * (0.6 + 0.4 * u)   // starts gently, then drops away
    }
    var onYes: () -> Void = {}
    var onLater: () -> Void = {}

    // Current walk segment. The window position and the leg cycle both read it, so the feet match the ground.
    var moveStart = Date()
    var moveDistance: CGFloat = 0
    var walkedBefore: CGFloat = 0
    static let ramp = 0.35   // seconds to get up to speed / to come to a stop

    var moveDuration: Double { max(Double(moveDistance / Walker.speed) + Self.ramp, Self.ramp * 2) }

    /// Distance covered in the current segment: steady pace with a short ease at each end.
    func segmentDistance(at date: Date) -> CGFloat {
        let T = moveDuration
        let u = min(max(date.timeIntervalSince(moveStart) / T, 0), 1)
        let r = min(Self.ramp / T, 0.5)
        let p: Double
        if u < r { p = u * u / (2 * r * (1 - r)) }
        else if u > 1 - r { p = 1 - (1 - u) * (1 - u) / (2 * r * (1 - r)) }
        else { p = (u - r / 2) / (1 - r) }
        return moveDistance * CGFloat(p)
    }

    /// Total distance walked since the character appeared.
    func walked(at date: Date) -> CGFloat { walkedBefore + segmentDistance(at: date) }
}

/// Filmed action clips (drink_000.png, drink_001.png, ... plus drink.json). Frames are decoded as they are
/// needed and only a handful are kept in memory, so a ten-second clip costs a few megabytes, not hundreds.
final class ClipStore {
    static let shared = ClipStore()
    struct Clip { let frames: Int; let fps: Double; let start: Int }
    private(set) var clips: [String: Clip] = [:]
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private var pending: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "clip-decode", qos: .userInitiated)

    func reload() {
        var found: [String: Clip] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: Skin.poseDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  info["clip"] as? Bool == true,
                  let n = info["frames"] as? Double, n >= 2 else { continue }
            found[f.deletingPathExtension().lastPathComponent.lowercased()] = Clip(frames: Int(n), fps: info["fps"] as? Double ?? 24, start: Int(info["start"] as? Double ?? 0))
        }
        lock.lock(); clips = found; cache.removeAll(); order.removeAll(); pending.removeAll(); lock.unlock()
    }

    private func decode(_ name: String, _ idx: Int) -> NSImage? {
        // the built-in character ships as HEIC to keep the app small; a custom pose set is PNG
        let base = Skin.poseDir.appendingPathComponent(String(format: "%@_%03d", name, idx))
        var url = base.appendingPathExtension("heic")
        if !FileManager.default.fileExists(atPath: url.path) { url = base.appendingPathExtension("png") }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func store(_ key: String, _ img: NSImage) {
        cache[key] = img
        order.append(key)
        while order.count > 14 { cache[order.removeFirst()] = nil }
    }

    /// The frame to show now. Also starts decoding the next few in the background so playback stays smooth.
    func frame(_ name: String, _ idx: Int) -> NSImage? {
        guard let clip = clips[name] else { return nil }
        let key = "\(name)/\(idx)"
        lock.lock()
        var img = cache[key]
        lock.unlock()
        if img == nil, let decoded = decode(name, idx) {
            img = decoded
            lock.lock(); store(key, decoded); lock.unlock()
        }
        for step in 1...4 {
            let next = (idx + step) % clip.frames
            let k = "\(name)/\(next)"
            lock.lock()
            let need = cache[k] == nil && !pending.contains(k)
            if need { pending.insert(k) }
            lock.unlock()
            guard need else { continue }
            queue.async { [weak self] in
                guard let self else { return }
                let d = self.decode(name, next)
                self.lock.lock()
                self.pending.remove(k)
                if let d, self.clips[name] != nil { self.store(k, d) }
                self.lock.unlock()
            }
        }
        return img
    }
}

/// Optional user-supplied character image (PNG with transparent background).
final class Skin: ObservableObject {
    static let shared = Skin()
    static let file = Store.dir.appendingPathComponent("character.png")
    @Published var image: NSImage?

    /// Which character is in use: "builtin2" (Built-in 1, the 3D kid shipped inside the app, the default),
    /// "drawn" (Built-in 2) or "custom". The stored values predate the labels being swapped.
    @Published var choice: String = "drawn" {
        didSet { UserDefaults.standard.set(choice, forKey: "characterChoice") }
    }
    /// A custom pose set the user added: transparent PNGs named walk1, wave, drink1, ... plus optional filmed clips.
    static let customPoseDir = Store.dir.appendingPathComponent("character")
    /// Built-in 2's files: inside the app bundle, or next to the project when run from source.
    static let bundledDir: URL? = {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("character2"), fm.fileExists(atPath: r.path) { return r }
        let dev = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/character2")
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }()
    static var hasCustom: Bool {
        let n = (try? FileManager.default.contentsOfDirectory(atPath: customPoseDir.path))?.filter { $0.hasSuffix(".png") }.count ?? 0
        return n > 0 || FileManager.default.fileExists(atPath: file.path)
    }
    /// Folder the active character's pose images and clips are read from.
    static var poseDir = URL(fileURLWithPath: "/nonexistent")
    @Published var sprites: [String: NSImage] = [:]

    /// Switch character and load its files.
    func select(_ c: String) {
        choice = c
        apply()
    }

    private func apply() {
        switch choice {
        case "builtin2": Skin.poseDir = Skin.bundledDir ?? URL(fileURLWithPath: "/nonexistent")
        case "custom": Skin.poseDir = Skin.customPoseDir
        default: Skin.poseDir = URL(fileURLWithPath: "/nonexistent")
        }
        sprites = Skin.loadSprites()
        image = choice == "custom" && sprites.isEmpty ? NSImage(contentsOf: Skin.file) : nil
        loadWalk()
    }

    /// Frames of a filmed walk cycle (walk_000, walk_001, ...), in order. Empty if the pose set has none.
    @Published var walkSeq: [NSImage] = []
    /// Ground one full stride covers, in the character's unscaled points, and how long that stride takes naturally.
    var walkStride: CGFloat = 105
    var walkCycleSeconds: Double = 1.0

    /// Reads the walk frames out of `sprites` and decodes them up front, so the first walk does not stutter.
    func loadWalk() {
        let names = sprites.keys.filter { $0.hasPrefix("walk_") }.sorted()
        var seq: [NSImage] = []
        for n in names {
            guard let img = sprites[n], let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if let decoded = ctx.makeImage() { seq.append(NSImage(cgImage: decoded, size: img.size)) }
        }
        walkSeq = seq.count >= 6 ? seq : []
        walkStride = 105
        walkCycleSeconds = 1.0
        ClipStore.shared.reload()
        if let data = try? Data(contentsOf: Skin.poseDir.appendingPathComponent("walk.json")),
           let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let v = info["stride"] as? Double, v > 10 { walkStride = CGFloat(v) }
            if let f = info["frames"] as? Double, let fps = info["fps"] as? Double, fps > 0 { walkCycleSeconds = f / fps }
        }
    }

    /// Walking pace in points per second. A filmed walk moves at the pace that keeps its feet planted,
    /// a touch brisker than it was filmed.
    var walkSpeed: CGFloat {
        guard !walkSeq.isEmpty else { return 165 * CGFloat(walkPace) }
        return walkStride * CGFloat(scale) / CGFloat(walkCycleSeconds) * CGFloat(walkPace)
    }
    /// Walk speed setting: 1.0 is the natural pace (for a filmed walk, exactly as filmed).
    @Published var walkPace: Double = UserDefaults.standard.object(forKey: "walkPace") as? Double ?? 1.3 {
        didSet { UserDefaults.standard.set(walkPace, forKey: "walkPace") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "characterChoice")
        choice = saved ?? (Skin.bundledDir != nil ? "builtin2" : (Skin.hasCustom ? "custom" : "drawn"))
        if choice == "builtin2" && Skin.bundledDir == nil { choice = "drawn" }
        apply()
    }

    static func loadSprites() -> [String: NSImage] {
        var out: [String: NSImage] = [:]
        let files = (try? FileManager.default.contentsOfDirectory(at: poseDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where ["png", "heic"].contains(f.pathExtension.lowercased()) {
            let name = f.deletingPathExtension().lastPathComponent.lowercased()
            // frames of filmed clips (drink_012 ...) are streamed by ClipStore, not loaded here
            if name.contains("_") && !name.hasPrefix("walk_") { continue }
            if let img = NSImage(contentsOf: f) { out[name] = img }
        }
        return out
    }

    /// Copy a folder of pose PNGs (and any clip files) in as the custom character, and switch to it.
    func usePoses(from folder: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: Skin.customPoseDir)
        try? fm.createDirectory(at: Skin.customPoseDir, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where ["png", "json"].contains(f.pathExtension.lowercased()) {
            try? fm.copyItem(at: f, to: Skin.customPoseDir.appendingPathComponent(f.lastPathComponent))
        }
        select("custom")
    }

    /// First pose that exists, in order of preference.
    func sprite(_ names: String...) -> NSImage? {
        for n in names { if let img = sprites[n] { return img } }
        return sprites["wave"] ?? sprites["idle"] ?? sprites.values.first
    }
    @Published var scale: Double = UserDefaults.standard.object(forKey: "characterScale") as? Double ?? 1.5 {
        didSet { UserDefaults.standard.set(scale, forKey: "characterScale") }
    }
    /// Size of the floating window for the current character scale.
    var panelSize: NSSize { NSSize(width: max(300, 170 * scale), height: 230 * scale + 170) }

    // Behaviour
    @Published var stopAt: String = UserDefaults.standard.string(forKey: "stopAt") ?? "left" {        // "left" | "center"
        didSet { UserDefaults.standard.set(stopAt, forKey: "stopAt") }
    }
    @Published var exitTo: String = UserDefaults.standard.string(forKey: "exitTo") ?? "left" {        // "left" | "right"
        didSet { UserDefaults.standard.set(exitTo, forKey: "exitTo") }
    }
    @Published var entrance: String = UserDefaults.standard.string(forKey: "entrance") ?? "walk" {    // "walk" | "peek" | "random"
        didSet { UserDefaults.standard.set(entrance, forKey: "entrance") }
    }
    @Published var corner: String = UserDefaults.standard.string(forKey: "corner") ?? "bottomRight" {
        didSet { UserDefaults.standard.set(corner, forKey: "corner") }
    }
    /// Window size for the peek entrance: room for the visible half of the character plus the bubble beside it.
    func peekSize(for spot: String) -> NSSize {
        let cw = 170 * scale, ch = 230 * scale
        switch PeekSpot(spot).kind {
        case .side:
            // lying in from the side: wide enough for the body plus the bubble next to the head
            let c = Skin.sideCentre(scale: scale)
            return NSSize(width: c.x + ch / 2 * CGFloat(sin(Skin.sideAngle * .pi / 180)) + 290, height: c.y + cw * 0.45)
        case .hang:
            return NSSize(width: cw + 270, height: ch + 24)
        case .rise:
            return NSSize(width: max(cw + 250, 420), height: ch * Skin.peekVisible + 70)
        }
    }
    /// Share of the character that shows when peeking. Pose images reach further out, so they come in a bit more.
    static var peekVisible: Double { shared.sprites.isEmpty ? 0.6 : 0.7 }
    static let sideAngle = 50.0    // how far it tips over when leaning in from the side, degrees
    /// Where the character's centre sits (from the top corner) when it leans in from the side edge.
    static func sideCentre(scale: Double) -> CGPoint {
        let ch = 230 * scale
        return CGPoint(x: (ch * peekVisible - ch / 2) * sin(sideAngle * .pi / 180), y: ch * 0.52)
    }
    @Published var autoLeave: Bool = UserDefaults.standard.bool(forKey: "autoLeave") {
        didSet { UserDefaults.standard.set(autoLeave, forKey: "autoLeave") }
    }
    @Published var snoozeMinutes: Double = UserDefaults.standard.object(forKey: "snoozeMinutes") as? Double ?? 10 {
        didSet { UserDefaults.standard.set(snoozeMinutes, forKey: "snoozeMinutes") }
    }
    @Published var autoSeconds: Double = UserDefaults.standard.object(forKey: "autoSeconds") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(autoSeconds, forKey: "autoSeconds") }
    }

    /// Use a single image as the custom character, and switch to it.
    func use(_ url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Store.dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: Skin.file)
        try? fm.removeItem(at: Skin.customPoseDir)
        try? fm.copyItem(at: url, to: Skin.file)
        select("custom")
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension View {
    func at(_ x: CGFloat, _ y: CGFloat) -> some View { position(x: x, y: y) }
}

/// A front-view pose. Hand targets are in the character's 170x230 canvas.
struct Pose {
    var l = CGPoint(x: 54, y: 137)    // hand on the viewer's left
    var r = CGPoint(x: 116, y: 137)
    var lean = 0.0                    // upper body tilt, degrees
    var eye = 1.0                     // 1 open, 0 closed
    var pupil = 0.0                   // horizontal look offset
    var tilt = 0.0                    // bottle tilt, degrees clockwise
    var mouth = 0.0                   // 0 smile, 1 open
    var arm = 24.0                    // length of each arm segment; grows when reaching
    var lift = 0.0                    // rising onto the toes, points
    var head = 0.0                    // head tilt, degrees
    var sl = CGPoint.zero             // shoulder offsets (viewer's left / right)
    var sr = CGPoint.zero

    static func mix(_ a: Pose, _ b: Pose, _ t: Double) -> Pose {
        func f(_ x: Double, _ y: Double) -> Double { x + (y - x) * t }
        func p(_ x: CGPoint, _ y: CGPoint) -> CGPoint { CGPoint(x: f(x.x, y.x), y: f(x.y, y.y)) }
        return Pose(l: p(a.l, b.l), r: p(a.r, b.r), lean: f(a.lean, b.lean), eye: f(a.eye, b.eye),
                    pupil: f(a.pupil, b.pupil), tilt: f(a.tilt, b.tilt), mouth: f(a.mouth, b.mouth),
                    arm: f(a.arm, b.arm), lift: f(a.lift, b.lift), head: f(a.head, b.head),
                    sl: p(a.sl, b.sl), sr: p(a.sr, b.sr))
    }

    static func smooth(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// Eased interpolation through timed keyframes.
    static func track(_ keys: [(Double, Pose)], _ t: Double) -> Pose {
        guard let first = keys.first, t > first.0 else { return keys[0].1 }
        for i in 1..<keys.count where t <= keys[i].0 {
            let (t0, p0) = keys[i - 1], (t1, p1) = keys[i]
            return mix(p0, p1, smooth((t - t0) / (t1 - t0)))
        }
        return keys[keys.count - 1].1
    }

    /// The pose for an action, `t` seconds after the character stopped. Returns the pose and bottle water level.
    static func of(_ action: BuddyAction, at t: Double) -> (pose: Pose, water: Double) {
        let rest = Pose()
        var water = 0.9
        var target: Pose
        switch action {
        case .drink:
            // show the bottle, drink, "ahh", repeat
            let period = 6.0, u = t.truncatingRemainder(dividingBy: period)
            var show = rest; show.l = CGPoint(x: 26, y: 64)
            var drink = rest; drink.l = CGPoint(x: 66, y: 80); drink.tilt = 60 + sin(t * 9) * 3; drink.eye = 0.05
            var ahh = show; ahh.mouth = 1; ahh.eye = 0.05
            target = track([(0, show), (1.6, show), (2.2, drink), (3.8, drink), (4.4, ahh), (5.2, show), (period, show)], u)
            water = max(0.15, 0.9 - 0.2 * ((t / period).rounded(.down) + smooth((u - 2.2) / 1.6)))
        case .stretch:
            // reach for the ceiling on tiptoe, bend to each side, then roll the shoulders
            let period = 11.6, u = t.truncatingRemainder(dividingBy: period)
            var up = rest
            up.l = CGPoint(x: 80, y: 11); up.r = CGPoint(x: 90, y: 11)
            up.arm = 42; up.eye = 0.05
            var tall = up; tall.lift = 4 + sin(t * 7) * 0.8
            var bendL = up; bendL.lean = -17; bendL.head = -5
            var bendR = up; bendR.lean = 17; bendR.head = 5
            target = track([(0, up), (0.5, tall), (1.9, tall), (2.7, bendL), (3.7, bendL), (4.7, bendR), (5.7, bendR),
                            (6.4, up), (7.2, rest), (11.0, rest), (period, up)], u)
            // shoulder rolls: both shoulders circle up, back and down while the arms hang loose
            let env = smooth((u - 7.0) / 0.5) * smooth((11.1 - u) / 0.5)
            if env > 0 {
                let a = (u - 7.0) * 2 * .pi / 1.25
                let dy = -(1 - cos(a)) * 4.5 * env, dx = sin(a) * 3.5 * env
                target.sl = CGPoint(x: -dx, y: dy); target.sr = CGPoint(x: dx, y: dy)
                target.l.x -= dx; target.l.y += dy * 0.8
                target.r.x += dx; target.r.y += dy * 0.8
                target.head = sin(a) * 1.5 * env
            }
        case .eyes:
            // look away left and right, close the eyes, cover them with the palms
            let period = 8.0, u = t.truncatingRemainder(dividingBy: period)
            var lookL = rest; lookL.pupil = -2.5
            var lookR = rest; lookR.pupil = 2.5
            var closed = rest; closed.eye = 0
            var palms = closed; palms.l = CGPoint(x: 76, y: 51); palms.r = CGPoint(x: 94, y: 51)
            target = track([(0, lookL), (1.2, lookL), (2.0, lookR), (3.0, lookR), (3.6, closed), (4.3, palms),
                            (6.4, palms), (7.0, closed), (7.6, rest), (period, lookL)], u)
        case .wave, .auto:
            target = rest
            target.l = CGPoint(x: 26 + sin(t * 6) * 7, y: 58)
        }
        return (mix(rest, target, smooth(t / 0.6)), water)
    }
}

/// Shared colours and small drawing helpers for the built-in character.
enum Art {
    static let skin = Color(red: 0.89, green: 0.68, blue: 0.53)
    static let skinShade = Color(red: 0.78, green: 0.56, blue: 0.42)
    static let hair = Color(red: 0.11, green: 0.08, blue: 0.07)
    static let hairLight = Color(red: 0.32, green: 0.22, blue: 0.17)
    static let denim = Color(red: 0.36, green: 0.52, blue: 0.76)
    static let denimLight = Color(red: 0.47, green: 0.63, blue: 0.85)
    static let denimDark = Color(red: 0.25, green: 0.38, blue: 0.6)
    static let denimDeep = Color(red: 0.19, green: 0.29, blue: 0.48)
    static let tee = Color(red: 0.43, green: 0.43, blue: 0.47)
    static let teeDark = Color(red: 0.33, green: 0.33, blue: 0.37)
    static let jeans = Color(red: 0.2, green: 0.22, blue: 0.29)
    static let jeansDark = Color(red: 0.14, green: 0.15, blue: 0.21)
    static let eye = Color(red: 0.18, green: 0.11, blue: 0.08)

    static func ell(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h))
    }
    static func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
        Path(roundedRect: CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h), cornerRadius: r)
    }
    static func poly(_ pts: [CGPoint]) -> Path {
        var p = Path()
        p.addLines(pts)
        p.closeSubpath()
        return p
    }
    static func vGradient(_ a: Color, _ b: Color, _ y0: CGFloat, _ y1: CGFloat) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: [a, b]), startPoint: CGPoint(x: 0, y: y0), endPoint: CGPoint(x: 0, y: y1))
    }

    /// Soft contact shadow on the ground.
    static func shadow(_ ctx: GraphicsContext, _ cx: CGFloat, _ y: CGFloat, _ w: CGFloat) {
        ctx.fill(ell(cx, y, w, 12), with: .radialGradient(
            Gradient(colors: [.black.opacity(0.32), .black.opacity(0)]),
            center: CGPoint(x: cx, y: y), startRadius: 0, endRadius: w / 2))
    }

    /// A sleeve from shoulder to hand with a lighter cuff, then the hand.
    static func sleeve(_ ctx: GraphicsContext, _ s: CGPoint, _ e: CGPoint, _ h: CGPoint, color: Color, cuff: Color) {
        var p = Path()
        p.move(to: s); p.addLine(to: e); p.addLine(to: h)
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 15, lineCap: .round, lineJoin: .round))
        let dx = h.x - e.x, dy = h.y - e.y
        let d = max(0.001, (dx * dx + dy * dy).squareRoot())
        let ux = dx / d, uy = dy / d
        var c = Path()
        c.move(to: CGPoint(x: h.x - ux * 7, y: h.y - uy * 7))
        c.addLine(to: CGPoint(x: h.x - ux * 3, y: h.y - uy * 3))
        ctx.stroke(c, with: .color(cuff), style: StrokeStyle(lineWidth: 16, lineCap: .butt))
        let hand = CGPoint(x: h.x + ux * 3, y: h.y + uy * 3)
        ctx.fill(ell(hand.x, hand.y, 14, 14), with: .color(skin))
        ctx.fill(ell(hand.x + uy * 5, hand.y - ux * 5, 6, 6), with: .color(skin))   // thumb
    }

    /// Water bottle, drawn standing on the origin of `ctx`.
    static func bottle(_ ctx: GraphicsContext, water: Double) {
        let body = CGRect(x: -6.5, y: -29, width: 13, height: 31)
        ctx.fill(Path(roundedRect: CGRect(x: -3.5, y: -35, width: 7, height: 7), cornerRadius: 2),
                 with: .color(Color(red: 0.2, green: 0.5, blue: 0.9)))
        ctx.fill(Path(roundedRect: body, cornerRadius: 4.5), with: .color(Color(red: 0.84, green: 0.94, blue: 1).opacity(0.8)))
        let h = 29 * water
        ctx.fill(Path(roundedRect: CGRect(x: -5.5, y: 1 - h, width: 11, height: h), cornerRadius: 3.5),
                 with: .color(Color(red: 0.3, green: 0.68, blue: 1).opacity(0.8)))
        ctx.fill(Path(roundedRect: CGRect(x: -4, y: -25, width: 2.5, height: 20), cornerRadius: 1.2), with: .color(.white.opacity(0.55)))
        ctx.stroke(Path(roundedRect: body, cornerRadius: 4.5), with: .color(.white.opacity(0.9)), lineWidth: 1)
    }

    /// Sneaker with the ankle at the origin of `ctx`, toe pointing right.
    static func shoeSide(_ ctx: GraphicsContext, shade: Double) {
        ctx.fill(Path(roundedRect: CGRect(x: -11, y: -5, width: 31, height: 15), cornerRadius: 7), with: .color(Color(white: 0.98 * shade)))
        ctx.fill(Path(roundedRect: CGRect(x: -11, y: 6, width: 32, height: 5), cornerRadius: 2), with: .color(Color(white: 0.76 * shade)))
        ctx.fill(Path(roundedRect: CGRect(x: 10, y: -1, width: 10, height: 7), cornerRadius: 3.5), with: .color(Color(white: 0.88 * shade)))
        for i in 0..<3 {
            ctx.fill(Path(roundedRect: CGRect(x: CGFloat(i) * 4, y: -4, width: 2, height: 5), cornerRadius: 1), with: .color(Color(white: 0.7 * shade)))
        }
    }
}

/// Built-in character facing the viewer: denim jacket, grey tee, dark jeans, white sneakers.
struct CharacterFront: View {
    var pose: Pose
    var bottle = false
    var water = 0.9
    var hang = false      // dangling from the top edge by the viewer's-right hand

    /// Two-bone IK: where the elbow goes for a hand target. `side` is -1 for the viewer's left arm.
    func elbow(_ s: CGPoint, _ target: CGPoint, side: CGFloat, len: CGFloat) -> (elbow: CGPoint, hand: CGPoint) {
        var dx = target.x - s.x, dy = target.y - s.y
        var d = max(0.001, (dx * dx + dy * dy).squareRoot())
        if d > len * 2 - 0.2 { let k = (len * 2 - 0.2) / d; dx *= k; dy *= k; d = len * 2 - 0.2 }
        let ux = dx / d, uy = dy / d
        let h = (len * len - d * d / 4).squareRoot()
        // bend the elbow away from the body
        var px = -uy, py = ux
        if px * side < 0 || (px == 0 && py < 0) { px = -px; py = -py }
        return (CGPoint(x: s.x + dx / 2 + px * h, y: s.y + dy / 2 + py * h), CGPoint(x: s.x + dx, y: s.y + dy))
    }

    var body: some View {
        Canvas { base, _ in
            let cx: CGFloat = 85
            let ell = Art.ell, rr = Art.rr

            if !hang { Art.shadow(base, cx, 219, 104) }

            // legs and sneakers
            for sgn in [CGFloat(-1), 1] {
                let x = cx + sgn * 12
                let top = 140 - pose.lift
                base.fill(Art.poly([CGPoint(x: x - 12, y: top), CGPoint(x: x + 12, y: top),
                                    CGPoint(x: x + 9.5, y: 203), CGPoint(x: x - 9.5, y: 203)]),
                          with: Art.vGradient(Art.jeans, Art.jeansDark, 140, 205))
                base.fill(rr(x, 201, 20, 5, 1.5), with: .color(Art.jeansDark))
                let sx = x + sgn * 2
                base.fill(rr(sx, 206, 28, 15, 7.5), with: .color(Color(white: 0.98)))
                base.fill(rr(sx, 207, 12, 9, 4), with: .color(Color(white: 0.9)))
                base.fill(rr(sx, 212, 29, 5, 2), with: .color(Color(white: 0.76)))
            }

            // everything above the hips leans together
            var ctx = base
            ctx.translateBy(x: cx, y: 146 - pose.lift)
            ctx.rotate(by: .degrees(pose.lean))
            ctx.translateBy(x: -cx, y: -146)

            // tee
            ctx.fill(rr(cx, 114, 46, 64, 11), with: Art.vGradient(Art.tee, Art.teeDark, 84, 146))
            var neckline = Path()
            neckline.move(to: CGPoint(x: cx - 10, y: 84))
            neckline.addQuadCurve(to: CGPoint(x: cx + 10, y: 84), control: CGPoint(x: cx, y: 95))
            ctx.stroke(neckline, with: .color(Art.teeDark), lineWidth: 2.5)

            // open jacket: two panels with pockets, buttons and a hem band
            for sgn in [CGFloat(-1), 1] {
                let x = cx + sgn * 17.5
                ctx.fill(rr(x, 116, 20, 70, 9), with: Art.vGradient(Art.denimLight, Art.denim, 82, 150))
                ctx.fill(rr(x, 147, 20, 7, 3), with: .color(Art.denimDark))
                ctx.fill(rr(x, 104, 12, 3.5, 1.5), with: .color(Art.denimDark))
                ctx.stroke(rr(x, 110, 12, 11, 2.5), with: .color(Art.denimDark), lineWidth: 1.3)
                ctx.fill(ell(x, 105, 2.4, 2.4), with: .color(Color(red: 0.85, green: 0.72, blue: 0.5)))
                for by in [CGFloat(122), 132] {
                    ctx.fill(ell(cx + sgn * 10, by, 2.6, 2.6), with: .color(Color(red: 0.85, green: 0.72, blue: 0.5)))
                }
                // lapel
                ctx.fill(Art.poly([CGPoint(x: cx + sgn * 6, y: 82), CGPoint(x: cx + sgn * 24, y: 82),
                                   CGPoint(x: cx + sgn * 22, y: 92), CGPoint(x: cx + sgn * 10, y: 99)]),
                         with: .color(Art.denimDark))
            }

            // an arm raised above the head goes behind it; otherwise it is drawn in front of the face
            let arms: [(CGPoint, CGPoint, CGFloat)] = [
                (CGPoint(x: cx + 27 + pose.sr.x, y: 90 + pose.sr.y - (hang ? 5 : 0)), hang ? CGPoint(x: cx + 24, y: 7) : pose.r, 1),
                (CGPoint(x: cx - 27 + pose.sl.x, y: 90 + pose.sl.y), pose.l, -1)]
            // shoulder caps, so a shrug or roll moves the jacket and not just the sleeve
            for (sh, _, _) in arms { ctx.fill(ell(sh.x, sh.y + 1, 18, 18), with: .color(Art.denim)) }
            func drawArm(_ shoulder: CGPoint, _ target: CGPoint, _ side: CGFloat) {
                // the arm it hangs from is stretched out straight
                let a = elbow(shoulder, target, side: side, len: hang && side > 0 ? 42 : CGFloat(pose.arm))
                if bottle && side < 0 {
                    var b = ctx
                    b.translateBy(x: a.hand.x, y: a.hand.y)
                    b.rotate(by: .degrees(pose.tilt))
                    Art.bottle(b, water: water)
                }
                Art.sleeve(ctx, shoulder, a.elbow, a.hand, color: Art.denim, cuff: Art.denimDark)
            }
            for (s, t, side) in arms where t.y < 46 { drawArm(s, t, side) }

            // head, tilting at the neck
            var hc = ctx
            hc.translateBy(x: cx, y: 82)
            hc.rotate(by: .degrees(pose.head))
            hc.translateBy(x: -cx, y: -82)
            hc.fill(rr(cx, 80, 16, 14, 3), with: .color(Art.skinShade))
            for sgn in [CGFloat(-1), 1] {
                hc.fill(ell(cx + sgn * 24, 54, 10, 13), with: .color(Art.skin))
                hc.fill(ell(cx + sgn * 24.5, 54, 4, 7), with: .color(Art.skinShade))
            }
            let head = rr(cx, 51, 47, 54, 22)
            hc.fill(head, with: Art.vGradient(Art.skin, Art.skinShade.opacity(0.9), 40, 90))
            // beard: the lower face, with the cheeks and mouth carved out
            hc.drawLayer { l in
                l.clip(to: head)
                l.fill(Path(CGRect(x: 0, y: 53, width: 170, height: 40)), with: .color(Art.hair))
                l.fill(ell(cx, 53, 35, 27), with: .color(Art.skin))
                l.fill(ell(cx - 13, 59, 9, 6), with: .color(Color(red: 0.95, green: 0.5, blue: 0.45).opacity(0.3)))
                l.fill(ell(cx + 13, 59, 9, 6), with: .color(Color(red: 0.95, green: 0.5, blue: 0.45).opacity(0.3)))
            }
            // nose and moustache
            hc.fill(ell(cx, 57, 7, 8), with: .color(Art.skinShade))
            var mo = Path()
            mo.move(to: CGPoint(x: cx - 11, y: 65))
            mo.addQuadCurve(to: CGPoint(x: cx + 11, y: 65), control: CGPoint(x: cx, y: 59))
            hc.stroke(mo, with: .color(Art.hair), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if pose.mouth > 0.4 {
                hc.fill(ell(cx, 70, 10, 4 + 6 * pose.mouth), with: .color(Color(red: 0.42, green: 0.1, blue: 0.1)))
                hc.fill(ell(cx, 72, 6, 3 * pose.mouth), with: .color(Color(red: 0.85, green: 0.4, blue: 0.4)))
            } else {
                hc.drawLayer { l in
                    l.clip(to: Path(CGRect(x: 0, y: 67, width: 170, height: 20)))
                    l.fill(ell(cx, 67, 15, 11), with: .color(.white))
                }
            }
            // eyes and brows
            for sgn in [CGFloat(-1), 1] {
                let ex = cx + sgn * 9.5
                if pose.eye < 0.3 {
                    var p = Path()
                    p.move(to: CGPoint(x: ex - 5, y: 49))
                    p.addQuadCurve(to: CGPoint(x: ex + 5, y: 49), control: CGPoint(x: ex, y: 54))
                    hc.stroke(p, with: .color(Art.hair), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                } else {
                    hc.drawLayer { l in
                        l.clip(to: ell(ex, 49, 11, 11))
                        l.fill(ell(ex, 49, 11, 11), with: .color(.white))
                        l.fill(ell(ex + pose.pupil, 49.5, 6.5, 6.5), with: .color(Art.eye))
                        l.fill(ell(ex + pose.pupil - 1.3, 48, 2.2, 2.2), with: .color(.white))
                        l.fill(Path(CGRect(x: ex - 6, y: 43, width: 12, height: 11 * (1 - pose.eye))), with: .color(Art.skin))
                    }
                }
                var brow = hc
                brow.translateBy(x: ex, y: 40.5)
                brow.rotate(by: .degrees(Double(sgn) * 7))
                brow.fill(Path(roundedRect: CGRect(x: -6.5, y: -1.8, width: 13, height: 3.6), cornerRadius: 1.8), with: .color(Art.hair))
            }
            // hair: short sides, volume on top, a swept quiff
            hc.fill(rr(cx - 21.5, 41, 5, 22, 2.5), with: .color(Art.hair))
            hc.fill(rr(cx + 21.5, 41, 5, 22, 2.5), with: .color(Art.hair))
            hc.fill(ell(cx, 31, 52, 28), with: .color(Art.hair))
            var quiff = hc
            quiff.translateBy(x: cx + 4, y: 22)
            quiff.rotate(by: .degrees(-12))
            quiff.fill(Path(ellipseIn: CGRect(x: -19, y: -12, width: 38, height: 25)), with: .color(Art.hair))
            var shine = Path()
            shine.move(to: CGPoint(x: -8, y: -5))
            shine.addQuadCurve(to: CGPoint(x: 12, y: -3), control: CGPoint(x: 3, y: -10))
            quiff.stroke(shine, with: .color(Art.hairLight), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            for (s, t, side) in arms where t.y >= 46 { drawArm(s, t, side) }
        }
        .frame(width: 170, height: 230)
    }
}

/// Built-in character seen from the side, walking to the right.
/// The feet follow a real gait path (heel strike, planted stance, toe-off, swing) and the knees are solved from it.
struct CharacterSide: View {
    var phase: Double    // walk cycle angle, radians (2π = two steps)
    var amount: Double   // 0 = standing, 1 = full stride
    var bottle = true

    static let thigh: CGFloat = 32
    static let shin: CGFloat = 32
    static let step: CGFloat = 46     // how far a planted foot travels under the body
    static let stance = 0.6           // share of the cycle a foot spends on the ground
    /// Ground covered by one full cycle (two steps), in unscaled points.
    static var stride: CGFloat { step / CGFloat(stance) }

    /// Ankle position relative to the hip's ground point, and the foot's pitch (+ = toe up).
    func foot(_ cycle: Double) -> (x: CGFloat, lift: CGFloat, pitch: Double) {
        let c = cycle - cycle.rounded(.down)
        let x: Double, lift: Double, pitch: Double
        if c < Self.stance {
            // on the ground: lands on the heel, rolls flat, then peels off the toe
            let u = c / Self.stance
            let heelRise = Pose.smooth((u - 0.68) / 0.32)
            x = 0.5 - u
            lift = 8 * heelRise
            pitch = 16 * (1 - Pose.smooth(u / 0.16)) - 34 * heelRise
        } else {
            // in the air: swings forward, clearing the ground
            let v = (c - Self.stance) / (1 - Self.stance)
            let sv = Pose.smooth(v)
            x = -0.5 + sv
            lift = 8 * (1 - sv) + 9 * sin(.pi * v)
            pitch = -34 + 50 * sv
        }
        return (CGFloat(x * amount) * Self.step, CGFloat(lift * amount), pitch * amount)
    }

    func dir(_ deg: Double) -> CGPoint {   // unit vector, 0 = straight down, positive = forward
        let r = deg * .pi / 180
        return CGPoint(x: sin(r), y: cos(r))
    }

    /// Arm swing; `swing` is -1 (back) ... 1 (forward).
    func arm(_ swing: Double, reach: Double) -> (elbow: CGPoint, hand: CGPoint) {
        let a = 24 * swing * amount * reach
        let e = 8 + (10 + 14 * (swing + 1) / 2) * amount     // the elbow bends more on the forward swing
        let d1 = dir(a), d2 = dir(a + e)
        let elbow = CGPoint(x: d1.x * 24, y: d1.y * 24)
        return (elbow, CGPoint(x: elbow.x + d2.x * 24, y: elbow.y + d2.y * 24))
    }

    var body: some View {
        Canvas { base, _ in
            let cx: CGFloat = 85
            let ground: CGFloat = 214
            let ell = Art.ell, rr = Art.rr
            let cycle = phase / (2 * .pi)

            // hips are highest over the planted foot and dip when both feet are down
            let hipHeight = 62.5 - CGFloat(amount * (1.9 - 1.6 * cos(4 * .pi * (cycle - Self.stance / 2))))
            let hip = CGPoint(x: cx - 2 * CGFloat(amount), y: ground - 8 - hipHeight)
            let dy = hip.y - 140

            func drawLeg(_ f: (x: CGFloat, lift: CGFloat, pitch: Double), _ color: Color, _ shade: Double) {
                let ankle = CGPoint(x: hip.x + f.x, y: ground - 8 - f.lift)
                var dx = ankle.x - hip.x, dyy = ankle.y - hip.y
                var d = max(0.001, (dx * dx + dyy * dyy).squareRoot())
                let maxLen = Self.thigh + Self.shin - 0.3
                if d > maxLen { dx *= maxLen / d; dyy *= maxLen / d; d = maxLen }
                let ux = dx / d, uy = dyy / d
                let h = (Self.thigh * Self.thigh - d * d / 4).squareRoot()
                let knee = CGPoint(x: hip.x + dx / 2 + uy * h, y: hip.y + dyy / 2 - ux * h)   // knee bends forward
                var p = Path()
                p.move(to: hip); p.addLine(to: knee); p.addLine(to: ankle)
                base.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 19, lineCap: .round, lineJoin: .round))
                var shoe = base
                shoe.translateBy(x: ankle.x, y: ankle.y)
                shoe.rotate(by: .degrees(-f.pitch))
                Art.shoeSide(shoe, shade: shade)
            }

            Art.shadow(base, cx, ground + 5, 100)

            // the upper body leans slightly into the walk
            var ctx = base
            ctx.translateBy(x: hip.x, y: hip.y)
            ctx.rotate(by: .degrees(3.5 * amount))
            ctx.translateBy(x: -cx, y: -hip.y)
            let shoulder = CGPoint(x: cx - 1, y: 91 + dy)
            func y(_ v: CGFloat) -> CGFloat { v + dy }

            func drawArm(_ a: (elbow: CGPoint, hand: CGPoint), _ color: Color, _ cuff: Color, bottle: Bool) {
                let e = CGPoint(x: shoulder.x + a.elbow.x, y: shoulder.y + a.elbow.y)
                let h = CGPoint(x: shoulder.x + a.hand.x, y: shoulder.y + a.hand.y)
                if bottle {
                    var b = ctx
                    b.translateBy(x: h.x + 5, y: h.y + 6)
                    b.rotate(by: .degrees(8))
                    Art.bottle(b, water: 0.9)
                }
                Art.sleeve(ctx, shoulder, e, h, color: color, cuff: cuff)
            }

            // arms swing against the legs: the near arm is back when the near foot lands in front
            let swing = cos(2 * .pi * cycle)
            drawArm(arm(swing, reach: 1), Art.denimDark, Art.denimDeep, bottle: false)
            drawLeg(foot(cycle + 0.5), Art.jeansDark, 0.84)
            drawLeg(foot(cycle), Art.jeans, 1)

            // torso
            ctx.fill(rr(cx + 11, y(111), 12, 54, 5), with: .color(Art.tee))
            ctx.fill(rr(cx - 1, y(112), 34, 62, 13), with: Art.vGradient(Art.denimLight, Art.denim, y(82), y(144)))
            ctx.fill(rr(cx - 1, y(140), 34, 7, 3), with: .color(Art.denimDark))
            ctx.fill(Art.poly([CGPoint(x: cx - 6, y: y(81)), CGPoint(x: cx + 17, y: y(82)),
                               CGPoint(x: cx + 15, y: y(97)), CGPoint(x: cx + 4, y: y(90))]), with: .color(Art.denimDark))

            // head in profile, facing right
            ctx.fill(rr(cx + 1, y(80), 15, 14, 3), with: .color(Art.skinShade))
            let head = rr(cx + 2, y(51), 45, 53, 21)
            ctx.fill(head, with: Art.vGradient(Art.skin, Art.skinShade.opacity(0.9), y(40), y(90)))
            var nose = Path()
            nose.move(to: CGPoint(x: cx + 22, y: y(47)))
            nose.addQuadCurve(to: CGPoint(x: cx + 30, y: y(58)), control: CGPoint(x: cx + 27, y: y(50)))
            nose.addQuadCurve(to: CGPoint(x: cx + 22, y: y(61)), control: CGPoint(x: cx + 29, y: y(62)))
            nose.closeSubpath()
            ctx.fill(nose, with: .color(Art.skin))
            ctx.drawLayer { l in                                                        // beard
                l.clip(to: head)
                l.fill(Path(CGRect(x: 0, y: y(54), width: 170, height: 40)), with: .color(Art.hair))
                l.fill(ell(cx + 13, y(53), 26, 24), with: .color(Art.skin))
                l.fill(ell(cx + 10, y(59), 9, 6), with: .color(Color(red: 0.95, green: 0.5, blue: 0.45).opacity(0.3)))
            }
            ctx.fill(rr(cx + 19, y(64), 13, 4, 2), with: .color(Art.hair))              // moustache
            ctx.drawLayer { l in                                                        // smile
                l.clip(to: Path(CGRect(x: 0, y: y(67), width: 170, height: 20)))
                l.fill(ell(cx + 19, y(67), 10, 8), with: .color(.white))
            }
            ctx.fill(ell(cx - 3, y(55), 11, 14), with: .color(Art.skin))                // ear
            ctx.fill(ell(cx - 3, y(55), 5, 8), with: .color(Art.skinShade))
            ctx.fill(ell(cx + 15, y(49), 10, 10), with: .color(.white))
            ctx.fill(ell(cx + 17, y(49.5), 6, 6), with: .color(Art.eye))
            ctx.fill(ell(cx + 16, y(48), 2, 2), with: .color(.white))
            var brow = ctx
            brow.translateBy(x: cx + 15, y: y(40.5))
            brow.rotate(by: .degrees(6))
            brow.fill(Path(roundedRect: CGRect(x: -6, y: -1.8, width: 12, height: 3.6), cornerRadius: 1.8), with: .color(Art.hair))
            ctx.fill(ell(cx - 14, y(44), 18, 34), with: .color(Art.hair))               // back of the hair
            ctx.fill(ell(cx, y(31), 50, 28), with: .color(Art.hair))
            var quiff = ctx
            quiff.translateBy(x: cx + 11, y: y(22))
            quiff.rotate(by: .degrees(-12))
            quiff.fill(Path(ellipseIn: CGRect(x: -17, y: -11, width: 34, height: 23)), with: .color(Art.hair))
            var shine = Path()
            shine.move(to: CGPoint(x: -7, y: -4))
            shine.addQuadCurve(to: CGPoint(x: 11, y: -2), control: CGPoint(x: 3, y: -9))
            quiff.stroke(shine, with: .color(Art.hairLight), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // near arm, carrying the bottle (it swings less so the water stays put)
            drawArm(arm(-swing, reach: bottle ? 0.6 : 1), Art.denim, Art.denimDark, bottle: bottle)
        }
        .frame(width: 170, height: 230)
    }
}

struct Character: View {
    var walking: Bool
    var action: BuddyAction = .wave
    var since = Date()
    var walked: (Date) -> CGFloat = { CGFloat($0.timeIntervalSinceReferenceDate) * Walker.speed }
    var facingLeft = false
    var hang = false
    var body: some View {
        // amount eases between 0 (standing) and 1 (walking) so the stride blends in and out
        CharacterPose(amount: walking ? 1 : 0, action: action, since: since, walked: walked, facingLeft: facingLeft, hang: hang)
            .animation(.easeInOut(duration: 0.4), value: walking)
    }
}

/// Character built from pose images: it swaps between them and adds a little motion of its own.
struct SpriteCharacter: View {
    var t: Double          // seconds since it stopped
    var phase: Double      // walk cycle, radians (π per step)
    var walking: Bool
    var action: BuddyAction
    var facingLeft = false
    var hang = false
    @ObservedObject var skin = Skin.shared

    static let stride: CGFloat = 105   // ground covered by two steps, in unscaled points

    func has(_ name: String) -> Bool { skin.sprites[name] != nil }

    /// Name of the filmed clip for the current action (used when the pose set includes one).
    var clipName: String {
        switch action {
        case .drink: return "drink"
        case .stretch: return "stretch"
        case .eyes: return "eyes"
        case .wave, .auto: return "wave"
        }
    }

    /// Which pose shows at time `t`, and whether it is mirrored.
    func pose(at t: Double) -> (name: String, mirrored: Bool) {
        if hang { return (has("hang") ? "hang" : "stretch1", false) }   // arms up reads as holding on to the edge
        switch action {
        case .drink:
            // show the bottle, drink, "ahh", show it again
            let u = t.truncatingRemainder(dividingBy: 6.5)
            if u < 1.8 { return ("drink1", false) }
            if u < 4.0 { return ("drink2", false) }
            if u < 5.2 { return ("drink3", false) }
            return ("drink1", false)
        case .stretch:
            // reach up, bend one way, reach up, bend the other way, then roll the shoulders
            let rolls = has("shoulders")
            let u = t.truncatingRemainder(dividingBy: rolls ? 13 : 8.5)
            if u < 2 { return ("stretch1", false) }
            if u < 4 { return ("stretch2", false) }
            if u < 5.5 { return ("stretch1", false) }
            if u < 7.5 { return ("stretch2", true) }
            if u < 8.5 { return ("stretch1", false) }
            return (Int((u - 8.5) / 0.75) % 2 == 0 ? "shoulders" : "idle", false)
        case .eyes:
            // look one way, look the other way, then rest with the palms over the eyes
            let u = t.truncatingRemainder(dividingBy: 9)
            if u < 0.8 { return ("idle", false) }
            if u < 2.1 { return ("eye2", false) }
            if u < 3.4 { return ("eye3", false) }
            if u < 4.0 { return ("idle", false) }
            if u < 8.4 { return ("eyes", false) }
            return ("idle", false)
        case .wave, .auto:
            return ("wave", false)
        }
    }

    func image(_ name: String) -> NSImage? {
        switch name {
        case "drink2": return skin.sprite("drink2", "drink1")
        case "drink3": return skin.sprite("drink3", "drink1")
        case "stretch2": return skin.sprite("stretch2", "stretch1")
        case "shoulders": return skin.sprite("shoulders", "idle")
        case "eyes": return skin.sprite("eyes", "idle")
        case "eye2": return skin.sprite("eye2", "eyes2", "idle", "eyes")
        case "eye3": return skin.sprite("eye3", "eyes3", "idle", "eyes")
        case "idle": return skin.sprite("idle", "wave")
        default: return skin.sprite(name)
        }
    }

    /// Walk frames in stride order: a wide step, legs passing, the other wide step, legs passing.
    var walkFrames: [String] {
        let all = ["walk1", "walk3", "walk2", "walk4"].filter(has)
        return all.isEmpty ? ["walk1"] : all
    }

    func layer(_ name: String, mirrored: Bool) -> some View {
        Group {
            if let img = image(name) {
                // sized by height, so a wide pose (an arm out, the hang) does not shrink the whole character
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                    .frame(height: 230).fixedSize()
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1)
            }
        }
    }

    var body: some View {
        Group {
            if walking, !skin.walkSeq.isEmpty {
                // filmed walk cycle: the frame follows the ground covered, so the planted foot stays where it lands
                let n = skin.walkSeq.count
                let idx = Int(((phase / (2 * .pi)) * Double(n)).rounded(.down))
                Image(nsImage: skin.walkSeq[((idx % n) + n) % n]).resizable().interpolation(.high).scaledToFit()
                    .frame(height: 230).fixedSize()
                    .scaleEffect(x: facingLeft ? -1 : 1, y: 1)
            } else if walking {
                // the frames are spread evenly over one stride (two steps), with a bounce on each step
                let frames = walkFrames
                let pos = (phase / (2 * .pi)) * Double(frames.count)
                let idx = Int(pos.rounded(.down))
                let within = pos - pos.rounded(.down)
                let n = frames.count
                let bounce = abs(sin(phase)) * 4
                ZStack {
                    layer(frames[((idx % n) + n) % n], mirrored: facingLeft)
                    if within < 0.22, n > 1 {
                        // brief blend from the previous frame so the stride does not flicker
                        layer(frames[(((idx - 1) % n) + n) % n], mirrored: facingLeft).opacity(1 - within / 0.22)
                    }
                }
                .offset(y: -bounce)
            } else if !hang, let clip = ClipStore.shared.clips[clipName],
                      let img = ClipStore.shared.frame(clipName, (clip.start + Int(t * clip.fps)) % clip.frames) {
                // filmed action: plays through and loops, starting from its standing pose when the character stops
                Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                    .frame(height: 230).fixedSize()
            } else {
                let now = pose(at: t), before = pose(at: max(0, t - 0.16))
                let wiggle = action == .wave || action == .auto ? sin(t * 6) * 2.5 : 0
                ZStack {
                    layer(now.name, mirrored: now.mirrored)
                    if before.name != now.name || before.mirrored != now.mirrored {
                        // short cross-fade so the pose change is not a hard cut
                        let u = t.truncatingRemainder(dividingBy: 0.16) / 0.16
                        layer(before.name, mirrored: before.mirrored).opacity(max(0, 1 - u * 1.4))
                    }
                }
                .rotationEffect(.degrees(hang ? 0 : wiggle), anchor: .bottom)
                .scaleEffect(x: 1, y: hang ? 1 : 1 + 0.008 * sin(t * 2.2), anchor: .bottom)   // breathing
            }
        }
        .frame(width: 170, height: 230, alignment: hang ? .top : .bottom)
    }
}

struct CharacterPose: View, Animatable {
    var amount: Double
    var action: BuddyAction
    var since: Date
    var walked: (Date) -> CGFloat
    var facingLeft = false
    var hang = false
    @ObservedObject var skin = Skin.shared

    var animatableData: Double {
        get { amount }
        set { amount = newValue }
    }

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            // the legs advance with the ground actually covered, so they slow and stop with the window
            let stride = skin.sprites.isEmpty ? CharacterSide.stride : (skin.walkSeq.isEmpty ? SpriteCharacter.stride : skin.walkStride)
            let phase = 2 * .pi * Double(walked(ctx.date) / (stride * skin.scale))
            let idle = skin.sprites.isEmpty ? sin(t * 2) * 1.5 * (1 - amount) : 0
            Group {
                if !skin.sprites.isEmpty {
                    SpriteCharacter(t: max(0, ctx.date.timeIntervalSince(since)), phase: phase, walking: amount > 0.5,
                                    action: action, facingLeft: facingLeft, hang: hang)
                } else if let img = skin.image {
                    Image(nsImage: img).resizable().scaledToFit()
                        .rotationEffect(.degrees(sin(phase) * 4 * amount), anchor: .bottom)
                        .offset(y: -(1 - cos(phase * 2)) * 2.2 * amount)
                } else if amount > 0.5 {
                    // side view while walking
                    CharacterSide(phase: phase, amount: (amount - 0.5) * 2, bottle: action == .drink)
                        .scaleEffect(x: facingLeft ? -1 : 1, y: 1)   // mirrored when walking back to the left
                } else {
                    // turns to face you when it stops
                    let p = Pose.of(action, at: max(0, ctx.date.timeIntervalSince(since)))
                    CharacterFront(pose: p.pose, bottle: action == .drink, water: p.water, hang: hang)
                }
            }
            .scaleEffect(x: skin.image == nil ? 0.75 + 0.25 * abs(2 * amount - 1) : 1, y: 1, anchor: .bottom)
            .offset(y: -idle)
            .frame(width: 170, height: 230)
            .scaleEffect(skin.scale, anchor: .bottom)
            .frame(width: 170 * skin.scale, height: 230 * skin.scale, alignment: .bottom)
        }
    }
}

struct PillButton: ButtonStyle {
    var fill: Color
    var text: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(text)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Capsule().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(Capsule())
    }
}

struct BubbleTail: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct Bubble: View {
    @ObservedObject var model: WalkModel
    var tailUp = false
    var tailEdge: HorizontalAlignment = .center

    var tail: some View {
        BubbleTail().fill(.white).frame(width: 18, height: 10)
            .rotationEffect(.degrees(tailUp ? 180 : 0))
            .padding(.horizontal, 30)
    }

    var body: some View {
        VStack(alignment: tailEdge, spacing: 0) {
            if tailUp { tail }
            VStack(spacing: 14) {
                Text(model.message)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.12, green: 0.14, blue: 0.2))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(model.yesLabel) { model.onYes() }
                        .buttonStyle(PillButton(fill: Color(red: 0.2, green: 0.5, blue: 0.95), text: .white))
                    Button("Remind me later") { model.onLater() }
                        .buttonStyle(PillButton(fill: Color(red: 0.92, green: 0.93, blue: 0.96),
                                                text: Color(red: 0.25, green: 0.28, blue: 0.36)))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 20).fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3))
            if !tailUp { tail }
        }
        .environment(\.colorScheme, .light)
    }
}

/// One of the eight places the character can peek from, and how it gets there.
struct PeekSpot {
    enum Kind { case rise, side, hang }   // up from the bottom, in from a side edge, or dangling from the top
    static let all = ["topLeft", "top", "topRight", "left", "right", "bottomLeft", "bottom", "bottomRight"]
    let name: String
    init(_ name: String) { self.name = name }

    var kind: Kind {
        switch name {
        case "top": return .hang
        case "topLeft", "topRight", "left", "right": return .side
        default: return .rise
        }
    }
    var right: Bool { name == "right" || name.hasSuffix("Right") }
    var centred: Bool { name == "top" || name == "bottom" }
    var atTop: Bool { name.hasPrefix("top") }
    var midHeight: Bool { name == "left" || name == "right" }
}

/// Peek entrance: the character leans in from a screen corner or edge, with the bubble beside it.
struct PeekView: View {
    @ObservedObject var model: WalkModel
    @ObservedObject var skin = Skin.shared

    var body: some View {
        let cw = 170 * skin.scale, ch = 230 * skin.scale
        let vis = ch * Skin.peekVisible
        let spot = PeekSpot(model.corner)
        let right = spot.right
        let side: CGFloat = right ? 1 : -1
        ZStack {
            // an overlay, so the full-height character does not force the window taller than the part that shows
            Color.clear
                .overlay(alignment: Alignment(horizontal: right ? .trailing : .leading,
                                              vertical: spot.kind == .rise ? .bottom : .top)) {
                    TimelineView(.animation) { ctx in
                        let p = model.peekProgress(at: ctx.date)
                        let hidden = 1 - p
                        switch spot.kind {
                        case .rise:
                            // rises from below; the corners tip further in as they arrive, the centre comes straight up
                            // mirrored when the bubble is on the right, so the busy hand is on the bubble's side
                            Character(walking: false, action: model.action, since: model.stoppedAt)
                                .scaleEffect(x: right ? 1 : -1, y: 1)
                                .rotationEffect(.degrees(spot.centred ? 0 : -side * (5 + 9 * p)))
                                .offset(x: spot.centred ? 0 : side * hidden * 70, y: (ch - vis) + hidden * (vis + 70))
                        case .side:
                            // leans in sideways from the screen edge, tipping over a little more as it settles
                            let centre = Skin.sideCentre(scale: skin.scale)
                            // mirrored on the right edge, so the busy hand is always the upper one, next to the bubble
                            Character(walking: false, action: model.action, since: model.stoppedAt)
                                .scaleEffect(x: right ? -1 : 1, y: 1)
                                .rotationEffect(.degrees(-side * (Skin.sideAngle - 12 * hidden)))
                                .offset(x: -side * (centre.x - cw / 2) + side * hidden * (vis + 110), y: centre.y - ch / 2)
                        case .hang:
                            // drops down and dangles from the top edge by one hand, swinging gently
                            let t = ctx.date.timeIntervalSince(model.stoppedAt)
                            let swing = sin(t * 2.4) * (4 + 10 * exp(-t * 1.2))
                            // mirrored: hangs by the far hand, keeping the busy hand on the bubble's side
                            Character(walking: false, action: model.action, since: model.stoppedAt, hang: true)
                                .scaleEffect(x: skin.sprites["hang"] != nil ? 1 : -1, y: 1)
                                .rotationEffect(.degrees(swing), anchor: skin.sprites.isEmpty
                                    ? UnitPoint(x: 61.0 / 170, y: 7.0 / 230) : UnitPoint(x: 0.5, y: 0.01))
                                .offset(y: -max(hidden, 0) * (ch + 60))   // never drops past the edge it hangs from
                        }
                    }
                }
                .padding(.horizontal, spot.kind == .rise ? 6 : 0)
            if model.showBubble {
                Bubble(model: model, tailEdge: right ? .trailing : .leading)
                    .frame(maxWidth: 250)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: Alignment(horizontal: right ? .leading : .trailing, vertical: .top))
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3), value: model.showBubble)
    }
}

struct OverlayView: View {
    @ObservedObject var model: WalkModel
    @ObservedObject var skin = Skin.shared
    var body: some View {
        if model.peeking {
            PeekView(model: model)
        } else {
            walkLayout
        }
    }

    var walkLayout: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)
            if model.showBubble {
                Bubble(model: model).frame(maxWidth: 290).transition(.scale.combined(with: .opacity))
            }
            Character(walking: model.walking, action: model.action, since: model.stoppedAt,
                      walked: { [model] in model.walked(at: $0) }, facingLeft: model.facingLeft)
        }
        .padding(.bottom, 6)
        .frame(width: skin.panelSize.width, height: skin.panelSize.height)
        .animation(.spring(response: 0.3), value: model.showBubble)
    }
}

// MARK: - Walker (window that walks across the screen)

final class Walker: NSObject {
    private let panel: NSPanel
    let model = WalkModel()
    private var tick: (() -> Void)?
    private var leaving = false
    private var autoWork: DispatchWorkItem?
    private var gen = 0   // bumped for every showing, so delayed steps of an old one do nothing
    private var displayLink: AnyObject?
    private var timer: Timer?
    private var size: NSSize { Skin.shared.panelSize }
    static var speed: CGFloat { Skin.shared.walkSpeed }   // points per second

    override init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Skin.shared.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: OverlayView(model: model))
        host.sizingOptions = []   // the window decides its own size
        host.frame = NSRect(origin: .zero, size: Skin.shared.panelSize)
        panel.contentView = host
        super.init()
    }

    /// Walk in from the left, stop (left or centre), ask, then leave: back to the left or on to the right.
    /// Takes the character off screen right away, without reporting an outcome.
    func cancel() {
        gen += 1
        stopTicking()
        autoWork?.cancel()
        autoWork = nil
        leaving = true
        model.showBubble = false
        panel.orderOut(nil)
    }

    func present(_ r: Reminder, done: @escaping (Outcome) -> Void) {
        guard let screen = NSScreen.main else { done(.yes); return }
        cancel()            // clear anything left from a previous showing
        gen += 1
        let prefs = Skin.shared
        let vf = screen.visibleFrame
        if prefs.entrance == "peek" || (prefs.entrance == "random" && Bool.random()) {
            presentPeek(r, in: vf, done: done)
            return
        }
        model.peeking = false
        let y = vf.minY
        panel.setContentSize(size)
        let startX = vf.minX - size.width
        // the character is centred in the panel; "left" parks it about 170pt in from the screen edge
        let inset = (size.width - 170 * prefs.scale) / 2
        let stopX = prefs.stopAt == "center"
            ? vf.midX - size.width / 2
            : max(vf.minX + 8, vf.minX + 170 - inset)
        let endX = prefs.exitTo == "right" ? vf.maxX : startX

        model.message = r.message
        model.yesLabel = r.yesLabel
        model.action = r.resolvedAction
        model.showBubble = false
        model.walking = true
        model.facingLeft = false
        model.walkedBefore = 0
        model.moveDistance = 0
        leaving = false
        panel.setFrameOrigin(NSPoint(x: startX, y: y))
        panel.orderFrontRegardless()

        model.onYes = { [weak self] in self?.leave(to: endX, y: y) { done(.yes) } }
        model.onLater = { [weak self] in self?.leave(to: endX, y: y) { done(.later) } }

        move(to: stopX, y: y) { [weak self] in
            guard let self else { return }
            self.model.stoppedAt = Date()
            self.model.walking = false
            self.model.showBubble = true
            if prefs.autoLeave {
                // nobody clicked: carry on after a few seconds and come back later, like "Remind me later"
                let work = DispatchWorkItem { [weak self] in self?.leave(to: endX, y: y) { done(.ignored) } }
                self.autoWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(1, prefs.autoSeconds), execute: work)
            }
        }
    }

    /// Peek entrance: the window sits in a corner and the character slides into it.
    private func presentPeek(_ r: Reminder, in vf: NSRect, done: @escaping (Outcome) -> Void) {
        let prefs = Skin.shared
        let corner = prefs.corner == "random" ? PeekSpot.all.randomElement()! : prefs.corner
        let spot = PeekSpot(corner)
        let sz = prefs.peekSize(for: corner)
        let x: CGFloat
        if spot.centred { x = vf.midX - 170 * prefs.scale / 2 - (spot.kind == .rise ? 6 : 0) }   // character centred, bubble beside it
        else { x = spot.right ? vf.maxX - sz.width : vf.minX }
        let y: CGFloat = spot.atTop ? vf.maxY - sz.height : (spot.midHeight ? vf.midY - sz.height / 2 : vf.minY)
        stopTicking()

        model.message = r.message
        model.yesLabel = r.yesLabel
        model.action = r.resolvedAction
        model.showBubble = false
        model.walking = false
        model.corner = corner
        model.peekIn = true
        model.peekStart = Date().addingTimeInterval(0.06)   // let the window appear first
        model.peeking = true
        model.stoppedAt = Date()
        leaving = false
        panel.setFrame(NSRect(x: x, y: y, width: sz.width, height: sz.height), display: true)
        panel.orderFrontRegardless()

        model.onYes = { [weak self] in self?.leavePeek { done(.yes) } }
        model.onLater = { [weak self] in self?.leavePeek { done(.later) } }

        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.gen == g, !self.leaving, self.model.peeking else { return }
            self.model.showBubble = true
            if prefs.autoLeave {
                let work = DispatchWorkItem { [weak self] in self?.leavePeek { done(.ignored) } }
                self.autoWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + max(1, prefs.autoSeconds), execute: work)
            }
        }
    }

    private func leavePeek(_ done: @escaping () -> Void) {
        guard !leaving else { return }
        leaving = true
        autoWork?.cancel()
        autoWork = nil
        model.showBubble = false
        model.peekIn = false
        model.peekStart = Date()
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) { [weak self] in
            guard let self, self.gen == g else { return }
            self.panel.orderOut(nil)
            done()
        }
    }

    private func leave(to endX: CGFloat, y: CGFloat, _ done: @escaping () -> Void) {
        guard !leaving else { return }
        leaving = true
        autoWork?.cancel()
        autoWork = nil
        model.showBubble = false
        model.facingLeft = endX < panel.frame.origin.x
        model.walking = true
        move(to: endX, y: y) { [weak self] in
            self?.panel.orderOut(nil)
            done()
        }
    }

    private func move(to x: CGFloat, y: CGFloat, completion: @escaping () -> Void) {
        stopTicking()
        let fromX = panel.frame.origin.x
        model.walkedBefore += model.moveDistance
        model.moveDistance = abs(x - fromX)
        model.moveStart = Date()
        let dir: CGFloat = x >= fromX ? 1 : -1
        let end = model.moveStart.addingTimeInterval(model.moveDuration)

        tick = { [weak self] in
            guard let self else { return }
            let now = Date()
            if now >= end {
                self.stopTicking()
                self.panel.setFrameOrigin(NSPoint(x: x, y: y))
                completion()
            } else {
                self.panel.setFrameOrigin(NSPoint(x: fromX + dir * self.model.segmentDistance(at: now), y: y))
            }
        }
        // step once per screen refresh; fall back to a timer on older systems
        if #available(macOS 14.0, *), let screen = panel.screen ?? NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            let t = Timer(timeInterval: 1 / 120, target: self, selector: #selector(step), userInfo: nil, repeats: true)
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    @objc private func step() { tick?() }

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    var contentView: NSView? { panel.contentView }

    private func stopTicking() {
        if #available(macOS 14.0, *) { (displayLink as? CADisplayLink)?.invalidate() }
        displayLink = nil
        timer?.invalidate()
        timer = nil
        tick = nil
    }
}

// MARK: - Scheduler

/// How a showing ended.
enum Outcome { case yes, later, ignored }

/// Decides when each reminder shows. Every reminder has exactly one pending timer, so answering,
/// snoozing or ignoring one can never stack up extra copies of it.
final class Scheduler {
    var reminders: [Reminder] = []
    var minute: TimeInterval = 60                 // seconds per minute; tests shrink this
    var gap: TimeInterval = 60                    // quiet time between two showings
    var snoozeMinutes: () -> Double = { Skin.shared.snoozeMinutes }
    var present: (Reminder, @escaping (Outcome) -> Void) -> Void = { _, done in done(.yes) }
    /// Takes whatever is on screen away at once (used when a preview interrupts it).
    var cancelPresent: () -> Void = {}
    /// An ignored reminder (it left by itself) gets this many snoozed retries, then waits for its normal interval.
    static let ignoredRetries = 1

    private var due: [UUID: Timer] = [:]
    private var queue: [(r: Reminder, manual: Bool)] = []
    private(set) var showing: UUID?
    private var ignored: [UUID: Int] = [:]
    private var lastFinished: Date?
    private var pumpTimer: Timer?
    private var showToken = 0

    /// (Re)start from the current list. Each reminder's countdown begins again from now.
    func start(_ list: [Reminder]) {
        reminders = list
        due.values.forEach { $0.invalidate() }
        due.removeAll()
        let ids = Set(list.map(\.id))
        queue.removeAll { !ids.contains($0.r.id) }
        ignored = ignored.filter { ids.contains($0.key) }
        for r in list where r.id != showing && !queue.contains(where: { $0.r.id == r.id }) {
            arm(r.id, after: r.intervalMinutes)
        }
    }

    /// Show now (menu / Preview). Whatever is on screen is taken away immediately and this one starts instead,
    /// even if it is the same reminder (it restarts).
    func showNow(_ r: Reminder) {
        if let current = showing {
            showToken += 1                 // the interrupted showing can no longer report an outcome
            showing = nil
            cancelPresent()
            // the interrupted reminder simply goes back to its normal schedule
            if current != r.id, let c = reminders.first(where: { $0.id == current }) { arm(current, after: c.intervalMinutes) }
        }
        queue.removeAll { $0.r.id == r.id }
        queue.insert((r, true), at: 0)
        pump()
    }

    private func arm(_ id: UUID, after minutes: Double) {
        due[id]?.invalidate()
        let t = Timer(timeInterval: max(minutes, 0.1) * minute, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.due[id] = nil
            if let r = self.reminders.first(where: { $0.id == id }) { self.enqueue(r, manual: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        due[id] = t
    }

    private func enqueue(_ r: Reminder, manual: Bool) {
        if showing == r.id { return }
        if let i = queue.firstIndex(where: { $0.r.id == r.id }) {
            if manual { queue[i].manual = true }
            pump()
            return
        }
        queue.append((r, manual))
        pump()
    }

    private func pump() {
        guard showing == nil, let next = queue.first else { return }
        if !next.manual, let last = lastFinished {
            let wait = gap - Date().timeIntervalSince(last)
            if wait > 0 {
                pumpTimer?.invalidate()
                let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in self?.pump() }
                RunLoop.main.add(t, forMode: .common)
                pumpTimer = t
                return
            }
        }
        queue.removeFirst()
        let id = next.r.id
        // use the latest text/settings for this reminder if it was edited while waiting
        let r = reminders.first(where: { $0.id == id }) ?? next.r
        showing = id
        due[id]?.invalidate()
        due[id] = nil
        var finished = false
        showToken += 1
        let token = showToken
        present(r) { [weak self] outcome in
            // a showing can only end once, and not at all if a preview interrupted it
            guard let self, !finished, token == self.showToken else { return }
            finished = true
            self.showing = nil
            self.lastFinished = Date()
            if let current = self.reminders.first(where: { $0.id == id }) {
                switch outcome {
                case .yes:
                    self.ignored[id] = 0
                    self.arm(id, after: current.intervalMinutes)
                case .later:
                    self.ignored[id] = 0
                    self.arm(id, after: self.snoozeMinutes())
                case .ignored:
                    let n = (self.ignored[id] ?? 0) + 1
                    if n <= Self.ignoredRetries {
                        self.ignored[id] = n
                        self.arm(id, after: self.snoozeMinutes())
                    } else {
                        self.ignored[id] = 0
                        self.arm(id, after: current.intervalMinutes)
                    }
                }
            }
            self.pump()
        }
    }
}

// MARK: - Launch at login

enum LoginItem {
    /// Login items only work when running from a real .app bundle.
    static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Login item error: \(error)")
        }
    }
}

// MARK: - Settings

final class SettingsModel: ObservableObject {
    @Published var reminders: [Reminder] { didSet { Store.save(reminders); onChange() } }
    @Published var launchAtLogin = LoginItem.enabled
    var onChange: () -> Void = {}
    var onPreview: (Reminder) -> Void = { _ in }
    init(_ r: [Reminder]) { reminders = r }
}

extension BuddyAction {
    var symbol: String {
        switch self {
        case .drink: return "drop.fill"
        case .stretch: return "figure.cooldown"
        case .eyes: return "eye.fill"
        case .wave, .auto: return "hand.wave.fill"
        }
    }
    var tint: Color {
        switch self {
        case .drink: return Color(red: 0.2, green: 0.6, blue: 1)
        case .stretch: return Color(red: 1, green: 0.58, blue: 0.2)
        case .eyes: return Color(red: 0.6, green: 0.45, blue: 0.95)
        case .wave, .auto: return Color(red: 0.95, green: 0.4, blue: 0.55)
        }
    }
}

/// Rounded panel that groups related settings.
struct Card<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
        }
    }
}

/// One line inside a card: coloured icon, title, optional note, and a control on the right.
struct SettingRow<Control: View>: View {
    var icon: String
    var tint: Color
    var title: String
    var note: String? = nil
    var divider = true
    @ViewBuilder var control: Control
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(tint))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let note { Text(note).font(.caption).foregroundColor(.secondary) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            if divider { Divider().padding(.leading, 52) }
        }
    }
}

struct ReminderCard: View {
    @Binding var r: Reminder
    var onPreview: () -> Void
    var onDelete: () -> Void

    var body: some View {
        let action = r.resolvedAction
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: action.symbol)
                .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10).fill(action.tint.gradient))
            VStack(alignment: .leading, spacing: 8) {
                TextField("What should your buddy ask?", text: $r.message)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    Text("Every").foregroundColor(.secondary)
                    TextField("", value: $r.intervalMinutes, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 52).multilineTextAlignment(.center)
                    Text("min").foregroundColor(.secondary)
                    Spacer().frame(width: 6)
                    Picker("", selection: $r.action) {
                        ForEach(BuddyAction.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    .labelsHidden().frame(width: 128)
                    Spacer().frame(width: 6)
                    Text("Button").foregroundColor(.secondary)
                    TextField("Yes", text: $r.yesLabel).textFieldStyle(.roundedBorder).frame(width: 70)
                }
                .font(.system(size: 12))
            }
            Spacer(minLength: 4)
            VStack(spacing: 8) {
                Button(action: onPreview) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(action.tint.opacity(0.18)))
                        .foregroundColor(action.tint)
                }.buttonStyle(.plain).help("Preview this reminder now")
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                        .foregroundColor(.secondary)
                }.buttonStyle(.plain).help("Delete this reminder")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var skin = Skin.shared
    @State var tab = "reminders"

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text("Reminders").tag("reminders")
                Text("Behaviour").tag("behaviour")
                Text("Character").tag("character")
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case "behaviour": behaviour
                    case "character": character
                    default: reminders
                    }
                }
                .padding(20)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Changes save automatically").foregroundColor(.secondary)
                Spacer()
            }
            .font(.caption).padding(.horizontal, 20).padding(.vertical, 8)
        }
        .frame(width: 620, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var header: some View {
        HStack(spacing: 14) {
            // little portrait of the buddy
            ZStack {
                LinearGradient(colors: [Color(red: 0.45, green: 0.7, blue: 1), Color(red: 0.3, green: 0.45, blue: 0.95)],
                               startPoint: .top, endPoint: .bottom)
                if let img = skin.sprites.isEmpty ? nil : skin.sprite("idle", "wave") {
                    Image(nsImage: img).resizable().scaledToFit()
                        .frame(width: 60, height: 150, alignment: .top).offset(y: 46)
                } else if let img = skin.image {
                    Image(nsImage: img).resizable().scaledToFit().padding(4)
                } else {
                    CharacterFront(pose: Pose()).scaleEffect(0.62).offset(y: 42)
                }
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text("Strollo").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Your desk buddy · \(model.reminders.count) reminder\(model.reminders.count == 1 ? "" : "s") on watch")
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)
    }

    @ViewBuilder var reminders: some View {
        ForEach($model.reminders) { $r in
            ReminderCard(r: $r,
                         onPreview: { model.onPreview(r) },
                         onDelete: { model.reminders.removeAll { $0.id == r.id } })
        }
        Button {
            model.reminders.append(Reminder(message: "New reminder", intervalMinutes: 30))
        } label: {
            Label("Add reminder", systemImage: "plus")
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                    .foregroundColor(.accentColor.opacity(0.6)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundColor(.accentColor)
    }

    @ViewBuilder var behaviour: some View {
        Card(title: "Entrance") {
            SettingRow(icon: "sparkles", tint: .purple, title: "How it shows up",
                       note: skin.entrance == "peek" ? "Pops in from a corner or edge"
                           : skin.entrance == "random" ? "Walks in or peeks, picked at random each time"
                           : "Walks in along the bottom of the screen") {
                Picker("", selection: $skin.entrance) {
                    Text("Walk").tag("walk")
                    Text("Peek").tag("peek")
                    Text("Random").tag("random")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            if skin.entrance != "walk" {
                SettingRow(icon: "rectangle.inset.topleft.filled", tint: .indigo, title: "Peeks from",
                           note: skin.corner == "random" ? "A different one of the 8 spots each time" : nil,
                           divider: skin.entrance == "random") {
                    Picker("", selection: $skin.corner) {
                        Text("Top left").tag("topLeft")
                        Text("Top").tag("top")
                        Text("Top right").tag("topRight")
                        Divider()
                        Text("Left").tag("left")
                        Text("Right").tag("right")
                        Divider()
                        Text("Bottom left").tag("bottomLeft")
                        Text("Bottom").tag("bottom")
                        Text("Bottom right").tag("bottomRight")
                        Divider()
                        Text("Surprise me").tag("random")
                    }.labelsHidden().frame(width: 200)
                }
            }
            if skin.entrance != "peek" {
                SettingRow(icon: "mappin.and.ellipse", tint: .blue, title: skin.entrance == "random" ? "Walk stops at" : "Stops at") {
                    Picker("", selection: $skin.stopAt) {
                        Text("Left").tag("left")
                        Text("Center").tag("center")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                SettingRow(icon: "arrow.left.arrow.right", tint: .teal, title: "Then walks") {
                    Picker("", selection: $skin.exitTo) {
                        Text("Back left").tag("left")
                        Text("On right").tag("right")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                SettingRow(icon: "hare.fill", tint: .green, title: "Walk speed",
                           note: skin.walkPace < 0.95 ? "Strolling" : skin.walkPace <= 1.1 ? "Natural pace"
                               : skin.walkPace <= 1.5 ? "Brisk" : "In a hurry", divider: false) {
                    Slider(value: $skin.walkPace, in: 0.6...2.2, step: 0.05).frame(width: 160)
                    Text(String(format: "%.2f×", skin.walkPace)).monospacedDigit().foregroundColor(.secondary).frame(width: 44)
                }
            }
        }
        Card(title: "Timing") {
            SettingRow(icon: "hand.tap.fill", tint: .orange, title: "Leaves",
                       note: skin.autoLeave ? "Goes away by itself and comes back after the snooze" : "Stays until you answer") {
                Picker("", selection: $skin.autoLeave) {
                    Text("When I click").tag(false)
                    Text("By itself").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            if skin.autoLeave {
                SettingRow(icon: "timer", tint: .pink, title: "Waits for") {
                    Stepper("\(Int(skin.autoSeconds)) seconds", value: $skin.autoSeconds, in: 2...60, step: 1)
                }
            }
            SettingRow(icon: "moon.zzz.fill", tint: .indigo, title: "Snooze", note: "For \u{201C}Remind me later\u{201D}", divider: false) {
                Stepper("\(Int(skin.snoozeMinutes)) minutes", value: $skin.snoozeMinutes, in: 1...120, step: 1)
            }
        }
    }

    @ViewBuilder var character: some View {
        Card(title: "Look") {
            SettingRow(icon: "person.crop.square.fill", tint: .blue, title: "Character",
                       note: skin.choice == "builtin2" ? "3D kid with filmed walk and actions"
                           : skin.choice == "custom" ? (skin.sprites.isEmpty ? "Your own image" : "Your own pose set")
                           : "Drawn buddy with animations") {
                Picker("", selection: Binding(get: { skin.choice }, set: { skin.select($0) })) {
                    // the 3D kid is the default; the tags are the stored values and stay as they were
                    if Skin.bundledDir != nil { Text("Built-in 1 (3D)").tag("builtin2") }
                    Text("Built-in 2 (drawn)").tag("drawn")
                    if Skin.hasCustom || skin.choice == "custom" { Text("Custom").tag("custom") }
                }.labelsHidden().frame(width: 160)
                Menu("Add…") {
                    Button("Pose folder…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.message = "Pick a folder of transparent PNGs: walk1, walk2, wave, drink1, drink2, stretch1, stretch2, eyes, idle"
                        if panel.runModal() == .OK, let url = panel.url { skin.usePoses(from: url) }
                    }
                    Button("Single image…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.png, .gif, .jpeg]
                        if panel.runModal() == .OK, let url = panel.url { skin.use(url) }
                    }
                }.frame(width: 80)
            }
            SettingRow(icon: "arrow.up.left.and.arrow.down.right", tint: .green, title: "Size", divider: false) {
                Slider(value: $skin.scale, in: 0.8...3).frame(width: 200)
                Text(String(format: "%.1f×", skin.scale)).monospacedDigit().foregroundColor(.secondary).frame(width: 36)
            }
        }
        Card(title: "General") {
            SettingRow(icon: "power", tint: .gray, title: "Launch at login",
                       note: LoginItem.available ? nil : "Run the installed Strollo.app to enable this", divider: false) {
                Toggle("", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { LoginItem.set($0); model.launchAtLogin = LoginItem.enabled }))
                    .toggleStyle(.switch).labelsHidden().disabled(!LoginItem.available)
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    let settings = SettingsModel(Store.load())
    var reminders: [Reminder] { settings.reminders }
    let scheduler = Scheduler()
    var settingsWindow: NSWindow?
    let walker = Walker()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = symbol("figure.walk") {
            img.isTemplate = true
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "🚶"
        }
        settings.onChange = { [weak self] in self?.buildMenu(); self?.schedule() }
        settings.onPreview = { [weak self] r in self?.scheduler.showNow(r) }
        scheduler.cancelPresent = { [weak self] in self?.walker.cancel() }
        scheduler.present = { [weak self] r, done in
            guard let self else { done(.yes); return }
            self.walker.present(r, done: done)
        }
        buildMenu()
        schedule()
        if CommandLine.arguments.contains("--test"), let first = reminders.first { scheduler.showNow(first) }
    }

    func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func icon(for r: Reminder) -> String {
        let m = r.message.lowercased()
        if m.contains("water") || m.contains("drink") { return "drop.fill" }
        if m.contains("stretch") || m.contains("back") || m.contains("posture") { return "figure.cooldown" }
        if m.contains("eye") || m.contains("screen") { return "eye.fill" }
        if m.contains("walk") || m.contains("stand") { return "figure.walk" }
        if m.contains("eat") || m.contains("lunch") || m.contains("snack") { return "fork.knife" }
        if m.contains("break") || m.contains("rest") { return "cup.and.saucer.fill" }
        return "bell.fill"
    }

    func every(_ minutes: Double) -> String {
        if minutes >= 60, minutes.truncatingRemainder(dividingBy: 60) == 0 {
            let h = Int(minutes / 60)
            return h == 1 ? "every hour" : "every \(h) hours"
        }
        return "every \(minutes.formatted()) min"
    }

    func buildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem()
        let title = NSMutableAttributedString(
            string: "Strollo\n",
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.labelColor])
        let count = reminders.count
        title.append(NSAttributedString(
            string: count == 0 ? "No reminders yet — add one in Settings"
                               : "Your desk buddy · \(count) reminder\(count == 1 ? "" : "s") on watch",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        header.attributedTitle = title
        header.image = symbol("figure.wave")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if !reminders.isEmpty {
            if #available(macOS 14.0, *) {
                menu.addItem(.sectionHeader(title: "Call your buddy now"))
            }
            for (i, r) in reminders.enumerated() {
                let item = NSMenuItem(title: r.message, action: #selector(testReminder(_:)), keyEquivalent: "")
                item.tag = i; item.target = self
                item.image = symbol(icon(for: r))
                if #available(macOS 14.4, *) {
                    item.subtitle = every(r.intervalMinutes).capitalizedFirst
                } else {
                    item.title = "\(r.message)  ·  \(every(r.intervalMinutes))"
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.image = symbol("power")
        login.state = LoginItem.enabled ? .on : .off
        login.isEnabled = LoginItem.available
        menu.addItem(login)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        prefs.image = symbol("slider.horizontal.3")
        menu.addItem(prefs)
        let star = NSMenuItem(title: "Star on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        star.target = self
        star.image = symbol("star")
        menu.addItem(star)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Strollo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func schedule() { scheduler.start(reminders) }

    @objc func testReminder(_ s: NSMenuItem) { if reminders.indices.contains(s.tag) { scheduler.showNow(reminders[s.tag]) } }

    @objc func openGitHub() {
        if let url = URL(string: "https://github.com/kaisarsofi/strollo") { NSWorkspace.shared.open(url) }
    }

    @objc func toggleLogin() {
        LoginItem.set(!LoginItem.enabled)
        settings.launchAtLogin = LoginItem.enabled
        buildMenu()
    }

    @objc func openSettings() {
        settings.launchAtLogin = LoginItem.enabled
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Strollo Settings"
            w.contentView = NSHostingView(rootView: SettingsView(model: settings))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

@MainActor func renderPreview(to path: String) {
    // Dev helper: draw the built-in character to a PNG.
    func row(_ a: BuddyAction, _ times: [Double]) -> some View {
        HStack(spacing: 0) {
            ForEach(times, id: \.self) { t in
                let p = Pose.of(a, at: t)
                CharacterFront(pose: p.pose, bottle: a == .drink, water: p.water)
            }
        }
    }
    let view = VStack(spacing: 0) {
        row(.drink, [0.3, 1.2, 1.9, 3.0, 4.4, 9.0])
        row(.stretch, [1.2, 3.2, 7.3, 7.65, 7.95, 8.3])
        row(.eyes, [0.8, 2.5, 3.6, 4.0, 5.0, 7.3])
        HStack(spacing: 0) {
            ForEach(5..<10, id: \.self) { i in
                CharacterSide(phase: Double(i) * .pi / 5, amount: 1, bottle: false)
            }
            CharacterSide(phase: 0, amount: 0, bottle: false)
        }
        HStack(spacing: 0) {
            CharacterFront(pose: Pose.of(.wave, at: 2).pose)
            ForEach(0..<5, id: \.self) { i in
                CharacterSide(phase: Double(i) * .pi / 5, amount: 1, bottle: true)
            }
        }
    }.padding(20).background(Color(white: 0.14))
    let r = ImageRenderer(content: view)
    r.scale = 3
    if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

@MainActor func snapshot(_ view: some View, size: NSSize, to path: String) {
    // Dev helper: draw a view (including AppKit-backed controls) to a PNG through an offscreen window.
    let host = NSHostingView(rootView: view)
    host.sizingOptions = []
    host.frame = NSRect(origin: .zero, size: size)
    let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

// MARK: - Self-test (run with --self-test)

@MainActor func selfTest(ui: Bool) -> Bool {
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print((ok ? "  PASS  " : "  FAIL  ") + what)
        if !ok { failures += 1 }
    }
    func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    // ---- scheduler, on a compressed clock: one "minute" lasts 50 ms ----
    let minute = 0.05
    struct Shown { let at: Double; let end: Double; let id: UUID }
    func simulate(_ list: [Reminder], minutes: Double, snooze: Double = 5,
                  answer: @escaping (Reminder, Int) -> Outcome,
                  doubleDone: Bool = false,
                  during: ((Scheduler) -> Void)? = nil) -> (shown: [Shown], overlap: Bool) {
        let sch = Scheduler()
        sch.minute = minute
        sch.gap = minute
        sch.snoozeMinutes = { snooze }
        var log: [Shown] = []
        var up = 0, overlap = false
        let t0 = Date()
        sch.present = { r, done in
            up += 1
            if up > 1 { overlap = true }
            let start = Date().timeIntervalSince(t0) / minute
            let n = log.filter { $0.id == r.id }.count
            DispatchQueue.main.asyncAfter(deadline: .now() + minute * 0.3) {
                up -= 1
                log.append(Shown(at: start, end: Date().timeIntervalSince(t0) / minute, id: r.id))
                done(answer(r, n))
                if doubleDone { done(answer(r, n)) }
            }
        }
        sch.start(list)
        during?(sch)
        spin(minutes * minute)
        sch.start([])
        return (log, overlap)
    }
    func times(_ l: [Shown]) -> String { l.map { String(format: "%.0f", $0.at) }.joined(separator: ", ") }

    print("Scheduler")
    let one = [Reminder(message: "water", intervalMinutes: 10)]

    var r = simulate(one, minutes: 62) { _, _ in .ignored }
    check((7...9).contains(r.shown.count) && !r.overlap,
          "left by itself every time, interval 10 / snooze 5, over 60 min: \(r.shown.count) showings at [\(times(r.shown))] (expected about 8: one retry, then back to the interval)")

    r = simulate(one, minutes: 62) { _, _ in .yes }
    check((5...7).contains(r.shown.count), "answered Yes every time: \(r.shown.count) showings at [\(times(r.shown))] (expected about 6)")

    r = simulate(one, minutes: 62) { _, _ in .later }
    check((10...12).contains(r.shown.count), "Remind me later every time: \(r.shown.count) showings at [\(times(r.shown))] (expected about 11)")

    r = simulate(one, minutes: 62, answer: { _, _ in .yes }, doubleDone: true)
    check((5...7).contains(r.shown.count), "a showing that reports finishing twice is only counted once: \(r.shown.count) showings")

    r = simulate(one, minutes: 62, answer: { _, _ in .ignored }, during: { sch in for _ in 0..<25 { sch.start(one) } })
    check((7...9).contains(r.shown.count), "settings saved 25 times in a row does not multiply timers: \(r.shown.count) showings")

    do {
        // Preview pressed 10 times quickly: each press restarts it, and there is only ever one on screen
        let sch = Scheduler()
        sch.minute = minute; sch.gap = minute; sch.snoozeMinutes = { 5 }
        var up = 0, most = 0, cancels = 0, starts = 0
        sch.cancelPresent = { cancels += 1; up -= 1 }
        sch.present = { _, _ in starts += 1; up += 1; most = max(most, up) }
        sch.start(one)
        for _ in 0..<10 { sch.showNow(one[0]) }
        spin(0.05)
        check(starts == 10 && cancels == 9 && most == 1 && up == 1,
              "Preview pressed 10 times quickly: restarted \(cancels) times, never more than \(most) on screen, \(up) left showing")
        sch.start([])
    }

    // a preview interrupts what is showing: the old one stops at once and reports nothing, the new one starts
    do {
        let sch = Scheduler()
        sch.minute = minute; sch.gap = minute; sch.snoozeMinutes = { 5 }
        let a = Reminder(message: "a", intervalMinutes: 30), b = Reminder(message: "b", intervalMinutes: 30)
        var started: [String] = [], cancels = 0, up = 0, overlap = false
        var finishers: [(Outcome) -> Void] = []
        sch.cancelPresent = { cancels += 1; up -= 1 }
        sch.present = { r, done in up += 1; if up > 1 { overlap = true }; started.append(r.message); finishers.append(done) }
        sch.start([a, b])
        sch.showNow(a); spin(0.02)
        sch.showNow(b); spin(0.02)
        sch.showNow(b); spin(0.02)              // same one again: restarts
        finishers[0](.later); finishers[1](.yes)  // the interrupted showings try to report late
        spin(0.05)
        let stillShowingB = sch.showing == b.id
        finishers[2](.yes); up -= 1
        spin(minute * 12)
        check(started.prefix(3) == ["a", "b", "b"] && cancels == 2 && !overlap && stillShowingB,
              "a preview interrupts the current one: started \(started.prefix(3)), cancelled \(cancels) time(s), overlap \(overlap), late reports ignored \(stillShowingB)")
        check(started.count == 3, "interrupted reminders are not shown again straight away: \(started.count) showings in the next 12 min")
        sch.start([])
    }

    let three = [Reminder(message: "water", intervalMinutes: 10), Reminder(message: "stretch", intervalMinutes: 10),
                 Reminder(message: "eyes", intervalMinutes: 10)]
    r = simulate(three, minutes: 62) { _, _ in .ignored }
    let sorted = r.shown.sorted { $0.at < $1.at }
    var minGap = Double.infinity
    for i in sorted.indices.dropFirst() { minGap = min(minGap, sorted[i].at - sorted[i - 1].end) }
    let perReminder = three.map { rem in r.shown.filter { $0.id == rem.id }.count }
    check(!r.overlap, "three reminders due together never show at the same time")
    check(minGap >= 0.8, String(format: "there is a quiet gap between two showings (smallest gap %.1f min, expected about 1)", minGap))
    check(perReminder.allSatisfy { (6...9).contains($0) }, "three ignored reminders stay bounded: \(perReminder) showings each over 60 min")

    // ---- the real window: walk and peek, clicked and left alone ----
    if ui {
        print("Window flows (the character will appear on screen several times)")
        let prefs = Skin.shared
        let saved = (prefs.entrance, prefs.corner, prefs.stopAt, prefs.exitTo, prefs.autoLeave, prefs.autoSeconds)
        let walker = Walker()
        let rem = Reminder(message: "Self-test", intervalMinutes: 10)

        func flow(_ name: String, expect: Outcome, setup: () -> Void, click: ((WalkModel) -> Void)?) {
            setup()
            var outcomes: [Outcome] = []
            let began = Date()
            walker.present(rem) { outcomes.append($0) }
            var clicked = false
            while Date().timeIntervalSince(began) < 45 {
                spin(0.05)
                if let click, !clicked, walker.model.showBubble { clicked = true; spin(0.3); click(walker.model) }
                if !outcomes.isEmpty { break }
            }
            spin(1.0)   // anything fired twice would land in here
            let took = Date().timeIntervalSince(began) - 1.0
            check(outcomes.count == 1 && outcomes.first == expect && !walker.isVisible,
                  "\(name): ended \(outcomes.count) time(s) with \(outcomes.map { "\($0)" }), window hidden: \(!walker.isVisible), took \(String(format: "%.1f", took))s")
        }

        flow("walk, stop left, walk back, click Yes", expect: .yes,
             setup: { prefs.entrance = "walk"; prefs.stopAt = "left"; prefs.exitTo = "left"; prefs.autoLeave = false },
             click: { $0.onYes() })
        flow("walk, stop centre, walk on right, leaves by itself", expect: .ignored,
             setup: { prefs.entrance = "walk"; prefs.stopAt = "center"; prefs.exitTo = "right"; prefs.autoLeave = true; prefs.autoSeconds = 2 },
             click: nil)
        flow("walk, Yes clicked three times in a row", expect: .yes,
             setup: { prefs.entrance = "walk"; prefs.stopAt = "left"; prefs.exitTo = "left"; prefs.autoLeave = true; prefs.autoSeconds = 2 },
             click: { $0.onYes(); $0.onYes(); $0.onLater() })
        for spot in PeekSpot.all {
            flow("peek from \(spot), leaves by itself", expect: .ignored,
                 setup: { prefs.entrance = "peek"; prefs.corner = spot; prefs.autoLeave = true; prefs.autoSeconds = 2 },
                 click: nil)
        }
        // interrupt: start one, take it away mid-way, start another
        do {
            prefs.entrance = "walk"; prefs.stopAt = "center"; prefs.exitTo = "right"; prefs.autoLeave = false
            var first: [Outcome] = [], second: [Outcome] = []
            walker.present(rem) { first.append($0) }
            let began = Date()
            while !walker.model.showBubble && Date().timeIntervalSince(began) < 30 { spin(0.05) }
            spin(0.3)
            prefs.entrance = "peek"; prefs.corner = "bottomLeft"
            walker.present(rem) { second.append($0) }
            spin(0.2)
            let switched = walker.isVisible && walker.model.peeking
            let t1 = Date()
            while !walker.model.showBubble && Date().timeIntervalSince(t1) < 10 { spin(0.05) }
            walker.model.onYes()
            spin(1.5)
            check(first.isEmpty && second == [.yes] && switched && !walker.isVisible,
                  "walk interrupted by a peek preview: first reported \(first.count) outcome(s), second ended with \(second.map { "\($0)" }), switched at once: \(switched), window hidden at the end: \(!walker.isVisible)")
            // interrupt while it is walking away
            prefs.entrance = "walk"; prefs.stopAt = "left"; prefs.exitTo = "right"
            first = []; second = []
            walker.present(rem) { first.append($0) }
            let t2 = Date()
            while !walker.model.showBubble && Date().timeIntervalSince(t2) < 30 { spin(0.05) }
            walker.model.onYes(); spin(0.6)                 // now walking off
            prefs.entrance = "peek"; prefs.corner = "right"
            walker.present(rem) { second.append($0) }
            let t3 = Date()
            while !walker.model.showBubble && Date().timeIntervalSince(t3) < 10 { spin(0.05) }
            spin(2.0)                                         // the old walk-off must not close the new one
            let survived = walker.isVisible
            walker.model.onLater(); spin(1.5)
            check(first.isEmpty && second == [.later] && survived,
                  "preview during a walk-off: old one reported \(first.count) outcome(s), new one stayed up: \(survived), ended with \(second.map { "\($0)" })")
        }
        flow("peek, Remind me later double-clicked", expect: .later,
             setup: { prefs.entrance = "peek"; prefs.corner = "bottomRight"; prefs.autoLeave = false },
             click: { $0.onLater(); $0.onLater() })
        flow("peek, Yes clicked while set to leave by itself", expect: .yes,
             setup: { prefs.entrance = "peek"; prefs.corner = "top"; prefs.autoLeave = true; prefs.autoSeconds = 2 },
             click: { $0.onYes() })

        (prefs.entrance, prefs.corner, prefs.stopAt, prefs.exitTo, prefs.autoLeave, prefs.autoSeconds) = saved
    }

    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    return failures == 0
}

// MARK: - Demo recording (run with --render-demo <dir>)

/// Plays real reminders with the real window and records them onto a mock desktop, one PNG per frame.
/// Used to make the GIF in the README; the character also appears on screen while it runs.
@MainActor func renderDemo(to dir: String) {
    func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(max(0.001, seconds))) }
    guard let vf = NSScreen.main?.visibleFrame else { return }
    let prefs = Skin.shared
    let saved = (prefs.entrance, prefs.corner, prefs.stopAt, prefs.exitTo, prefs.autoLeave, prefs.scale, prefs.walkPace, prefs.choice)
    prefs.autoLeave = false; prefs.scale = 1.5; prefs.walkPace = 1.3
    if Skin.bundledDir != nil { prefs.select("builtin2") }

    let W = 900, H = 500, fps = 15.0
    let stripW: CGFloat = 1000                       // points of real screen the picture covers
    let k = CGFloat(W) / stripW
    let stripH = CGFloat(H) / k

    // backdrop: a full-screen code editor (dark theme) so the character has something realistic behind it
    func background(_ ctx: CGContext) {
        let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        defer { NSGraphicsContext.restoreGraphicsState() }
        func col(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
            NSColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
        }
        func fill(_ r: CGRect, _ c: NSColor) { c.setFill(); r.fill() }
        func text(_ t: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: NSColor, bold: Bool = false, mono: Bool = true) {
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                            : NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
            (t as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: c])
        }
        let w = CGFloat(W), h = CGFloat(H)
        fill(CGRect(x: 0, y: 0, width: w, height: h), col(0x1e1e1e))
        // activity bar and explorer
        fill(CGRect(x: 0, y: 22, width: 46, height: h - 22), col(0x333333))
        for i in 0..<5 {
            col(0xffffff, i == 0 ? 0.85 : 0.35).setFill()
            NSBezierPath(roundedRect: CGRect(x: 14, y: h - 62 - CGFloat(i) * 44, width: 18, height: 18), xRadius: 4, yRadius: 4).fill()
        }
        fill(CGRect(x: 46, y: 22, width: 200, height: h - 22), col(0x252526))
        text("EXPLORER", 62, h - 36, 10, col(0xbbbbbb), bold: true, mono: false)
        let files: [(String, Int, UInt32)] = [("strollo", 0, 0xcccccc), ("Sources", 1, 0xcccccc), ("main.swift", 2, 0xf05138),
                                              ("Package.swift", 1, 0xf05138), ("Resources", 1, 0xcccccc), ("character2", 2, 0xcccccc),
                                              ("README.md", 1, 0x519aba), ("make-app.sh", 1, 0x89e051)]
        for (i, f) in files.enumerated() {
            if i == 2 { fill(CGRect(x: 46, y: h - 74 - CGFloat(i) * 22, width: 200, height: 22), col(0x37373d)) }
            text(f.0, 62 + CGFloat(f.1) * 14, h - 69 - CGFloat(i) * 22, 12, col(f.2), mono: false)
        }
        // title bar and tabs
        fill(CGRect(x: 0, y: h - 22, width: w, height: 22), col(0x3c3c3c))
        for (i, c) in [0xff5f57, 0xfebc2e, 0x28c840].enumerated() {
            col(UInt32(c)).setFill(); NSBezierPath(ovalIn: CGRect(x: 12 + CGFloat(i) * 20, y: h - 16, width: 11, height: 11)).fill()
        }
        text("main.swift — strollo", w / 2 - 60, h - 18, 11, col(0xcccccc), mono: false)
        fill(CGRect(x: 246, y: h - 22 - 32, width: w - 246, height: 32), col(0x2d2d2d))
        fill(CGRect(x: 246, y: h - 22 - 32, width: 150, height: 32), col(0x1e1e1e))
        text("main.swift", 288, h - 22 - 22, 12, col(0xffffff), mono: false)
        text("Package.swift", 410, h - 22 - 22, 12, col(0x999999), mono: false)
        // code, with syntax colours
        let kw = col(0xc586c0), ty = col(0x4ec9b0), fn = col(0xdcdcaa), st = col(0xce9178), nm = col(0xb5cea8), cm = col(0x6a9955), pl = col(0xd4d4d4), vr = col(0x9cdcfe), bl = col(0x569cd6)
        let lines: [[(String, NSColor)]] = [
            [("// Strollo: a little buddy that walks in when it is time for a break", cm)],
            [("import ", kw), ("SwiftUI", ty)],
            [],
            [("struct ", bl), ("Reminder", ty), (": ", pl), ("Codable", ty), (" {", pl)],
            [("    var ", bl), ("message", vr), (": ", pl), ("String", ty)],
            [("    var ", bl), ("intervalMinutes", vr), (": ", pl), ("Double", ty), (" = ", pl), ("45", nm)],
            [("    var ", bl), ("action", vr), (": ", pl), ("BuddyAction", ty), (" = ", pl), (".drink", vr)],
            [("}", pl)],
            [],
            [("func ", bl), ("showReminder", fn), ("(_ r: ", pl), ("Reminder", ty), (") {", pl)],
            [("    let ", bl), ("buddy", vr), (" = ", pl), ("Character", ty), (".", pl), ("walkIn", fn), ("(from: ", pl), (".left", vr), (")", pl)],
            [("    buddy", vr), (".", pl), ("ask", fn), ("(", pl), ("\"Did you drink water?\"", st), (")", pl)],
            [("}", pl)],
        ]
        for (i, parts) in lines.enumerated() {
            let y = h - 22 - 32 - 30 - CGFloat(i) * 21
            text("\(i + 1)", 262, y, 12, col(0x858585))
            var x: CGFloat = 308
            for (t, c) in parts {
                text(t, x, y, 12.5, c)
                x += (t as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)]).width
            }
        }
        // status bar
        fill(CGRect(x: 0, y: 0, width: w, height: 22), col(0x007acc))
        text("main", 28, 5, 11, .white, mono: false)
        text("Swift", w - 150, 5, 11, .white, mono: false)
        text("UTF-8", w - 90, 5, 11, .white, mono: false)
        text("Ln 12, Col 2", w - 260, 5, 11, .white, mono: false)
    }

    var frameNo = 0
    let walker = Walker()
    /// Records until `until()` says stop. `originX` is the screen x that maps to the picture's left edge.
    func record(originX: CGFloat, until: () -> Bool) {
        var next = Date()
        while !until() {
            next = next.addingTimeInterval(1 / fps)
            spin(next.timeIntervalSinceNow)
            guard walker.isVisible, let view = walker.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            let f = walker.frame
            // skip frames where the character is still off the edge of the picture
            if f.maxX < originX + 20 || f.minX > originX + stripW - 20 { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let shot = rep.cgImage,
                  let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            background(ctx)
            ctx.draw(shot, in: CGRect(x: (f.minX - originX) * k, y: (f.minY - vf.minY) * k, width: f.width * k, height: f.height * k))
            if let img = ctx.makeImage() {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: String(format: "%@/d%04d.png", dir, frameNo)))
                frameNo += 1
            }
        }
        _ = stripH
    }

    func scene(_ r: Reminder, originX: CGFloat, hold: Double, setup: () -> Void) {
        setup()
        var done = false
        var shownAt: Date?
        var answered = false
        walker.present(r) { _ in done = true }
        record(originX: originX) {
            if walker.model.showBubble, shownAt == nil { shownAt = Date() }
            if let t = shownAt, !answered, Date().timeIntervalSince(t) > hold { answered = true; walker.model.onYes() }
            return done
        }
        spin(0.4)
    }

    // 1. walks in, drinks, walks on
    scene(Reminder(message: "Did you drink water?", intervalMinutes: 45), originX: vf.midX - stripW / 2, hold: 6.6) {
        prefs.entrance = "walk"; prefs.stopAt = "center"; prefs.exitTo = "right"
    }
    // 2. peeks from the bottom-right corner and stretches
    scene(Reminder(message: "Time to stretch your back!", intervalMinutes: 60, yesLabel: "Done"), originX: vf.maxX - stripW, hold: 6.2) {
        prefs.entrance = "peek"; prefs.corner = "bottomRight"
    }
    // 3. leans in from the left edge to rest its eyes
    scene(Reminder(message: "Rest your eyes for 20 seconds", intervalMinutes: 20, yesLabel: "Done"), originX: vf.minX, hold: 5.2) {
        prefs.entrance = "peek"; prefs.corner = "bottomLeft"
    }

    (prefs.entrance, prefs.corner, prefs.stopAt, prefs.exitTo, prefs.autoLeave, prefs.scale, prefs.walkPace) =
        (saved.0, saved.1, saved.2, saved.3, saved.4, saved.5, saved.6)
    prefs.select(saved.7)
    print("recorded \(frameNo) frames")
}

if let i = CommandLine.arguments.firstIndex(of: "--render-demo"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        renderDemo(to: CommandLine.arguments[i + 1])
    }
    exit(0)
}

if CommandLine.arguments.contains("--self-test") {
    let ok = MainActor.assumeIsolated { () -> Bool in
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        return selfTest(ui: !CommandLine.arguments.contains("--no-ui"))
    }
    exit(ok ? 0 : 1)
}

if let i = CommandLine.arguments.firstIndex(of: "--render-ui"), CommandLine.arguments.count > i + 1 {
    let dir = CommandLine.arguments[i + 1]
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let m = SettingsModel(Store.load())
        for tab in ["reminders", "behaviour", "character"] {
            snapshot(SettingsView(model: m, tab: tab), size: NSSize(width: 620, height: 640), to: "\(dir)/settings-\(tab).png")
        }
        let shots: [(String, Bool, BuddyAction, Double, Double)] = [
            ("walk-1", true, .wave, 0, 0.125), ("walk-2", true, .wave, 0, 0.375),
            ("walk-3", true, .wave, 0, 0.625), ("walk-4", true, .wave, 0, 0.875),
            ("stop-wave", false, .wave, 1.0, 0), ("stop-drink", false, .drink, 3.0, 0), ("stop-ahh", false, .drink, 7.6, 0),
            ("stop-show", false, .drink, 1.9, 0),
            ("stop-stretch", false, .stretch, 7.0, 0), ("stop-shoulders", false, .stretch, 8.8, 0),
            ("stop-look", false, .eyes, 1.5, 0), ("stop-eyes", false, .eyes, 6.0, 0)]
        for (name, walking, action, t, cycle) in shots {
            let wm = WalkModel()
            wm.message = "Did you drink water?"; wm.action = action; wm.walking = walking; wm.showBubble = !walking
            wm.stoppedAt = Date().addingTimeInterval(-t)
            wm.moveDistance = 0
            wm.walkedBefore = (Skin.shared.walkSeq.isEmpty ? SpriteCharacter.stride : Skin.shared.walkStride) * Skin.shared.scale * cycle
            snapshot(OverlayView(model: wm).background(Color(white: 0.2)), size: Skin.shared.panelSize, to: "\(dir)/\(name).png")
        }
        for corner in PeekSpot.all {
            let wm = WalkModel()
            wm.message = "Did you drink water?"; wm.action = .drink; wm.peeking = true
            wm.corner = corner; wm.peekStart = .distantPast; wm.showBubble = true
            wm.stoppedAt = Date().addingTimeInterval(-1.2)
            snapshot(PeekView(model: wm).background(Color(white: 0.2)), size: Skin.shared.peekSize(for: corner), to: "\(dir)/peek-\(corner).png")
        }
    }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated { renderPreview(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

Migration.run()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
