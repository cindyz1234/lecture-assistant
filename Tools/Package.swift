// swift-tools-version: 6.0
import PackageDescription

// Command-line tools for development and evaluation. Not shipped in the app.
let package = Package(
    name: "Tools",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../Packages/Shared"),
        .package(path: "../Packages/AudioCapture"),
        .package(path: "../Packages/Transcription"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(name: "transcribe", dependencies: [
            .product(name: "Shared", package: "Shared"),
            .product(name: "AudioCapture", package: "AudioCapture"),
            .product(name: "Transcription", package: "Transcription"),
            .product(name: "WhisperKitTranscription", package: "Transcription"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    ]
)
