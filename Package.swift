// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jev",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "JevCore", targets: ["JevCore"]),
        .library(name: "JevAX", targets: ["JevAX"]),
        .library(name: "JevDecide", targets: ["JevDecide"]),
        .library(name: "JevCapture", targets: ["JevCapture"]),
        .library(name: "JevServer", targets: ["JevServer"]),
        .executable(name: "jevd", targets: ["jevd"])
    ],
    targets: [
        .target(
            name: "JevCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "JevAX",
            dependencies: ["JevCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "JevDecide",
            dependencies: ["JevCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "JevCapture",
            dependencies: ["JevCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .target(
            name: "JevServer",
            dependencies: ["JevCore"],
            resources: [],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "jevd",
            dependencies: ["JevCore", "JevAX", "JevDecide", "JevCapture", "JevServer"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
