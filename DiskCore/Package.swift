// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DiskCore", targets: ["DiskCore"]),
        .executable(name: "diskscan", targets: ["diskscan"]),
    ],
    targets: [
        .target(
            name: "DiskCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "diskscan",
            dependencies: ["DiskCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DiskCoreTests",
            dependencies: ["DiskCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
