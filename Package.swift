// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchClip",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchClip", targets: ["NotchClip"])
    ],
    targets: [
        // Pure logic: models, storage, search, privacy rules. Foundation only.
        .target(name: "NotchClipCore", path: "Sources/NotchClipCore"),
        // macOS services and the notch user interface.
        .target(name: "NotchClipKit", dependencies: ["NotchClipCore"], path: "Sources/NotchClipKit"),
        // Thin executable entry point.
        .executableTarget(name: "NotchClip", dependencies: ["NotchClipKit"], path: "Sources/NotchClip"),
        .testTarget(name: "NotchClipCoreTests", dependencies: ["NotchClipCore"], path: "Tests/NotchClipCoreTests"),
        .testTarget(name: "NotchClipKitTests", dependencies: ["NotchClipKit", "NotchClipCore"], path: "Tests/NotchClipKitTests")
    ]
)
