// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PierApp",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // C bridging module for Rust FFI
        .systemLibrary(
            name: "CPierCore",
            path: "pier-bridge",
            pkgConfig: nil,
            providers: []
        ),
        // Main executable target
        .executableTarget(
            name: "PierApp",
            dependencies: ["CPierCore"],
            path: "PierApp/Sources",
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L", "pier-core/target/release",
                    "-L", "pier-core/target/debug",
                    "-lpier_core",
                ]),
                // System frameworks needed
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
