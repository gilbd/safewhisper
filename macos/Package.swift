// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SafeWhisperMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SafeWhisperMac", targets: ["SafeWhisperMac"])
    ],
    targets: [
        .executableTarget(name: "SafeWhisperMac")
    ]
)
