// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bezier",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bezier", targets: ["Bezier"]),
    ],
    targets: [
        // Browser state: spaces, sidebar tree, favorites, archive, persistence. No UI, no engine.
        .target(name: "BezierCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Engine-agnostic web content API (modelled on Arc's ADKClient boundary).
        .target(name: "BezierEngine"),
        // Development engine backed by WKWebView. Swapped for the Chromium (CEF) engine later.
        .target(name: "EngineWebKit", dependencies: ["BezierEngine"]),
        // The app: AppKit window chrome + SwiftUI sidebar / command bar.
        .executableTarget(
            name: "Bezier",
            dependencies: ["BezierCore", "BezierEngine", "EngineWebKit"]
        ),
        .testTarget(name: "BezierCoreTests", dependencies: ["BezierCore"]),
    ]
)
