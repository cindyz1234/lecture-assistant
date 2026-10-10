// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Storage",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Storage", targets: ["Storage"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "Storage", dependencies: [
            "Shared",
            .product(name: "GRDB", package: "GRDB.swift"),
        ]),
        .testTarget(name: "StorageTests", dependencies: [
            "Storage",
            .product(name: "Shared", package: "Shared"),
        ]),
    ]
)
