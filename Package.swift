// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ScreenlistCreator",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ScreenlistCreator",
            path: "Sources/ScreenlistCreator",
            swiftSettings: [
                .swiftLanguageVersion(.v5)
            ]
        )
    ]
)
