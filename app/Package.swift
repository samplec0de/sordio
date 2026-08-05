// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sordio",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SordioCore"),
        .executableTarget(name: "Sordio", dependencies: ["SordioCore"]),
        .testTarget(name: "SordioCoreTests", dependencies: ["SordioCore"]),
    ]
)
