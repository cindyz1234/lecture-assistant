// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
    ],
    targets: [
        .target(name: "AudioCapture", dependencies: ["Shared"]),
        .testTarget(name: "AudioCaptureTests", dependencies: [
            "AudioCapture",
            .product(name: "Shared", package: "Shared"),
        ]),
    ]
)
