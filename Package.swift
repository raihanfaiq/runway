// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Runway",
    platforms: [.macOS(.v14)],
    dependencies: [
        // GPU terminal engine: libghostty via the GhosttyKit wrapper.
        // Pinned to a specific commit — upstream's C API is still alpha, so we
        // deliberately avoid tracking a moving branch.
        .package(
            url: "https://github.com/briannadoubt/GhosttyKit.git",
            revision: "f3756807a61a42dba3dc1d866a1fd865f1ddfe21"
        )
    ],
    targets: [
        .executableTarget(
            name: "Runway",
            dependencies: [
                .product(name: "GhosttyKit", package: "GhosttyKit")
            ],
            path: "Sources/Runway",
            // The app is entirely main-thread (SwiftUI); the author's build relied
            // on module-wide default MainActor isolation. Scope it to this target
            // only — applying it to GhosttyKit breaks its C-function-pointer code.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        )
    ],
    swiftLanguageModes: [.v6]
)
