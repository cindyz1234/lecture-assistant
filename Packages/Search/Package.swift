// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Search",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Search", targets: ["Search"]),
    ],
    dependencies: [
        .package(path: "../Shared"),
    ],
    targets: [
        .target(name: "Search", dependencies: ["Shared"]),
    ]
)
