// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HardwareDecoder",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "hardware-decoder", targets: ["HardwareDecoderCLI"]),
        .library(name: "HardwareDecoderCore", targets: ["HardwareDecoderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "HardwareDecoderCore",
            path: "Sources/HardwareDecoderCore"
        ),
        .executableTarget(
            name: "HardwareDecoderCLI",
            dependencies: [
                "HardwareDecoderCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/HardwareDecoderCLI"
        ),
        .testTarget(
            name: "HardwareDecoderCoreTests",
            dependencies: ["HardwareDecoderCore"],
            path: "Tests/HardwareDecoderCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
