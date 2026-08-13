// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeToken",
    defaultLocalization: "zh-Hans",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "VibeToken", targets: ["VibeToken"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.5")
    ],
    targets: [
        .executableTarget(
            name: "VibeToken",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/VibeToken",
            exclude: ["Info.plist"],
            resources: [.process("Resources")],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ])
            ]
        ),
        .testTarget(
            name: "VibeTokenTests",
            dependencies: [
                "VibeToken",
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Tests/VibeTokenTests"
        )
    ]
)
