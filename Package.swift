// swift-tools-version: 5.9
import PackageDescription

// ClaudeBridger has no external dependencies on purpose: it must build and run
// offline, and everything it needs (JSON, file IO, SwiftUI) ships with the OS.
//
// The SwiftUI layer is a separate library so component behaviour and layout can be
// tested headlessly, without launching the app or driving the UI.
let package = Package(
    name: "ClaudeBridger",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClaudeBridger", targets: ["ClaudeBridger"]),
        .library(name: "ClaudeBridgerCore", targets: ["ClaudeBridgerCore"]),
        .library(name: "ClaudeBridgerUI", targets: ["ClaudeBridgerUI"])
    ],
    targets: [
        .target(
            name: "ClaudeBridgerCore",
            path: "Sources/ClaudeBridgerCore"
        ),
        .target(
            name: "ClaudeBridgerUI",
            dependencies: ["ClaudeBridgerCore"],
            path: "Sources/ClaudeBridgerUI"
        ),
        .executableTarget(
            name: "ClaudeBridger",
            dependencies: ["ClaudeBridgerCore", "ClaudeBridgerUI"],
            path: "Sources/ClaudeBridger"
        ),
        // Renders the README screenshots offscreen: no screen-recording permission, no visible
        // window. Not part of the app bundle; see scripts/render-screenshots.sh.
        .executableTarget(
            name: "ScreenshotRenderer",
            dependencies: ["ClaudeBridgerCore", "ClaudeBridgerUI"],
            path: "Sources/ScreenshotRenderer"
        ),
        .testTarget(
            name: "ClaudeBridgerCoreTests",
            dependencies: ["ClaudeBridgerCore"],
            path: "Tests/ClaudeBridgerCoreTests"
        ),
        .testTarget(
            name: "ClaudeBridgerUITests",
            dependencies: ["ClaudeBridgerUI", "ClaudeBridgerCore"],
            path: "Tests/ClaudeBridgerUITests"
        )
    ]
)
