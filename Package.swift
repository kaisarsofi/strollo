// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Strollo",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Strollo", path: "Sources/Strollo")]
)
