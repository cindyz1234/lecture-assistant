// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioDSP",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AudioDSP", targets: ["AudioDSP"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
    ],
    targets: [
        .target(name: "AudioDSP", dependencies: ["Shared"]),
    ]
)
