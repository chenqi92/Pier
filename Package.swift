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
                    // OpenSSL (Homebrew, static) — required by git2, russh (libssh2)
                    "/opt/homebrew/opt/openssl@3/lib/libssl.a",
                    "/opt/homebrew/opt/openssl@3/lib/libcrypto.a",
                    // zlib — required by git2 (compression)
                    "-lz",
                    // iconv — required by git2 (path encoding)
                    "-liconv",
                ]),
                // System frameworks needed
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
            ]
        ),
    ]
)
