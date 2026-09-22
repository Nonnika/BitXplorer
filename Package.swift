// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "BitXplore",
    platforms: [
        .macOS(.v27)
    ],
    targets: [
        .executableTarget(
            name: "BitXplore",
            path: "Sources/BitXplore",
            resources: [
                .copy("../../AppIcon.icns")
            ]
        )
    ]
)
