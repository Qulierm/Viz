// swift-tools-version: 5.9
// Headless SwiftPM build for Viz. The Xcode project (Viz.xcodeproj) is unchanged and
// remains the canonical build path on machines that have Xcode.
import PackageDescription

let package = Package(
    name: "Viz",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Viz", targets: ["Viz"])
    ],
    dependencies: [
        // Pinned to the revision recorded in Viz.xcodeproj/.../swiftpm/Package.resolved
        .package(url: "https://github.com/alienator88/AlinFoundation", revision: "f61241c2ea1856ef41cbfc965afe9d756121456f"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "2.4.0")
    ],
    targets: [
        .executableTarget(
            name: "Viz",
            dependencies: [
                .product(name: "AlinFoundation", package: "AlinFoundation"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Viz",
            exclude: [
                ".DS_Store",
                "Assets.xcassets",
                "Icon",
                "Info.plist",
                "LICENSE",
                "README.md",
                "Viz.entitlements",
                "Viz.icon",
                "announcements.json",
                "water.mp3"
            ]
        )
    ]
)
