// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Summarization",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Summarization", targets: ["Summarization"]),
        .library(name: "MLXSummarization", targets: ["MLXSummarization"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../MLXSupport"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        // Map-reduce summarization logic. No ML dependencies.
        .target(name: "Summarization", dependencies: ["Shared"]),
        // Adapter that runs an MLX LLM behind `TextGenerator`.
        .target(name: "MLXSummarization", dependencies: [
            "Summarization",
            .product(name: "Shared", package: "Shared"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "MLXSupport", package: "MLXSupport"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .testTarget(name: "SummarizationTests", dependencies: [
            "Summarization",
            .product(name: "Shared", package: "Shared"),
        ]),
    ]
)
