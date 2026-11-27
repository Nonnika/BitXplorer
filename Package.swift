// swift-tools-version: 6.4
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "BitXplore",
    platforms: [
        .macOS(.v27)
    ],
    targets: [
        .executableTarget(
            name: "BitXplore",
            path: "Sources/BitXplore",
            exclude: ["Info.plist"],
            resources: [
                .copy("../../AppIcon.icns")
            ],
            linkerSettings: [
                // 把 Info.plist 嵌入可执行文件，系统菜单随之显示为中文（见该文件注释）
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                              "-Xlinker", "\(packageRoot)/Sources/BitXplore/Info.plist"])
            ]
        )
    ]
)
