// swift-tools-version: 6.0
import PackageDescription

// Shared helpers for MLX model adapters (summarization, search).
let package = Package(
    name: "MLXSupport",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "MLXSupport", targets: ["MLXSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "0.11.0"),
    ],
    targets: [
        .target(name: "MLXSupport", dependencies: [
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
        ]),
    ]
)
