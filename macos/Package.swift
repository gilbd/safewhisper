// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhisperFlowMac",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WhisperFlowMac", targets: ["WhisperFlowMac"])
    ],
    targets: [
        .executableTarget(name: "WhisperFlowMac")
    ]
)
