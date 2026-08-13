// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "JustSayIt",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
    ],
    targets: [
        .target(
            name: "JustSayItCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "JustSayIt",
            dependencies: ["JustSayItCore"]
        ),
        .testTarget(
            name: "JustSayItTests",
            dependencies: ["JustSayItCore"]
        ),
    ]
)
