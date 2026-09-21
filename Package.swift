// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "DuoXplore",
    platforms: [
        .macOS(.v27)
    ],
    targets: [
        .executableTarget(
            name: "DuoXplore",
            path: "Sources/DuoXplore",
            resources: [
                .copy("../../AppIcon.icns")
            ]
        )
    ]
)
