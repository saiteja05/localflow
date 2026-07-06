// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalFlowKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FlowCore", targets: ["FlowCore"]),
        .library(name: "CleanupKit", targets: ["CleanupKit"]),
        .library(name: "HotkeyKit", targets: ["HotkeyKit"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
        .library(name: "InsertKit", targets: ["InsertKit"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .executable(name: "localflow-cli", targets: ["localflow-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.4"),
    ],
    targets: [
        .target(name: "CleanupKit"),
        .target(name: "HotkeyKit"),
        .target(name: "CaptureKit"),
        .target(name: "InsertKit"),
        .target(name: "TranscribeKit", dependencies: [
            "CaptureKit",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .target(name: "Persistence", dependencies: ["CleanupKit", "HotkeyKit"]),
        .target(name: "FlowCore", dependencies: [
            "CleanupKit", "HotkeyKit", "CaptureKit", "TranscribeKit", "InsertKit", "Persistence",
        ]),
        .executableTarget(name: "localflow-cli", dependencies: ["FlowCore"]),
        .testTarget(name: "CleanupKitTests", dependencies: ["CleanupKit"]),
        .testTarget(name: "HotkeyKitTests", dependencies: ["HotkeyKit"]),
        .testTarget(name: "CaptureKitTests", dependencies: ["CaptureKit"]),
        .testTarget(name: "TranscribeKitTests", dependencies: ["TranscribeKit"]),
        .testTarget(name: "InsertKitTests", dependencies: ["InsertKit"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "FlowCoreTests", dependencies: ["FlowCore"]),
    ]
)
