// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Search", targets: ["Search"]),
        .library(name: "MLXSearch", targets: ["MLXSearch"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(path: "../MLXSupport"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
    ],
    targets: [
        // Passages, vector index and hybrid retrieval. No ML dependencies.
        .target(name: "Search", dependencies: ["Shared"]),
        // Adapter that runs an MLX sentence-embedding model behind `TextEmbedder`.
        .target(name: "MLXSearch", dependencies: [
            "Search",
            .product(name: "Shared", package: "Shared"),
            .product(name: "MLXSupport", package: "MLXSupport"),
            .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers"),
        ]),
        .testTarget(name: "SearchTests", dependencies: [
            "Search",
            .product(name: "Shared", package: "Shared"),
        ]),
    ]
)
