// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Vocaret",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Pinned: "from:" would let a future major/minor break `git clone && build`
        // for other people without warning.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", .upToNextMinor(from: "0.9.0")),
        // Optional second ASR engine (NVIDIA Parakeet TDT v3 on Core ML). Pinned
        // to a minor: its API is still moving.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.5")),
    ],
    targets: [
        .target(
            name: "VocaretCore",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Security"),
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
