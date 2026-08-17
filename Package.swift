// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Vocaret",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned: "from:" would let a future major/minor break `git clone && build`
        // for other people without warning.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.9.0")),
    ],
    targets: [
        .target(
            name: "VocaretCore",
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
            name: "Vocaret",
            dependencies: ["VocaretCore"]
        ),
        .testTarget(
            name: "VocaretTests",
            dependencies: ["VocaretCore"]
        ),
    ]
)
