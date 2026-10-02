// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Clips",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Clips", path: "Sources/Clips", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
