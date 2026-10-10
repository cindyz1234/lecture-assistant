// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Transcription", targets: ["Transcription"]),
        .library(name: "WhisperKitTranscription", targets: ["WhisperKitTranscription"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        // Engine protocol and model-independent logic. No ML dependencies.
        .target(name: "Transcription", dependencies: ["Shared"]),
        // Adapter that runs WhisperKit models behind `AudioWindowTranscriber`.
        .target(name: "WhisperKitTranscription", dependencies: [
            "Transcription",
            .product(name: "Shared", package: "Shared"),
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .testTarget(name: "TranscriptionTests", dependencies: [
            "Transcription",
            .product(name: "Shared", package: "Shared"),
        ]),
    ]
)
