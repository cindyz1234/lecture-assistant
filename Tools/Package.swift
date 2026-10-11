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
        .package(path: "../Packages/Summarization"),
        .package(path: "../Packages/Storage"),
        .package(path: "../Packages/Search"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(name: "ToolSupport"),
        .executableTarget(name: "transcribe", dependencies: [
            "ToolSupport",
            .product(name: "Shared", package: "Shared"),
            .product(name: "AudioCapture", package: "AudioCapture"),
            .product(name: "Transcription", package: "Transcription"),
            .product(name: "WhisperKitTranscription", package: "Transcription"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "summarize", dependencies: [
            "ToolSupport",
            .product(name: "Shared", package: "Shared"),
            .product(name: "Summarization", package: "Summarization"),
            .product(name: "MLXSummarization", package: "Summarization"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "qaeval", dependencies: [
            "ToolSupport",
            .product(name: "Shared", package: "Shared"),
            .product(name: "Storage", package: "Storage"),
            .product(name: "Search", package: "Search"),
            .product(name: "MLXSearch", package: "Search"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .executableTarget(name: "searchbench", dependencies: [
            "ToolSupport",
            .product(name: "Shared", package: "Shared"),
            .product(name: "Storage", package: "Storage"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
    ]
)
