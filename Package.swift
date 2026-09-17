// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Limita",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Limita",
            path: "Limita",
            exclude: ["Info.plist"],
            resources: []
        )
    ]
)
