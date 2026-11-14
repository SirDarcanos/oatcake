// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Oatcake",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Speech models on the Neural Engine. Only the Diarizer trait: no text-to-speech and no
        // prebuilt text-normalisation library. Pinned exactly; see README › Speech models.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: ["Diarizer"]),
    ],
    targets: [
        // What Oatcake and its recorder agree on: the files they pass between them and what's in
        // each. Shared, so the two programs can't drift apart.
        .target(
            name: "RecorderContract",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Everything that isn't a window: files, recordings, the speech pipeline, the calendar,
        // summaries, Ask and updates.
        .target(
            name: "OatcakeCore",
            dependencies: ["RecorderContract", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The app, and (with --analyse) the analysis helper it runs for each recording.
        .executableTarget(
            name: "Oatcake",
            dependencies: ["OatcakeCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The recorder: its own app bundle inside Oatcake.app, so macOS asks for microphone and
        // system-audio permission for it alone.
        .executableTarget(
            name: "OatcakeRecorder",
            dependencies: ["RecorderContract"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "OatcakeCoreTests",
            dependencies: ["OatcakeCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
