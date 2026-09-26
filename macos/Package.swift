// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Limita",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Limita",
            path: "Limita",
            exclude: ["Info.plist", "Resources"],
            resources: []
        ),
        .testTarget(name: "LimitaTests", dependencies: ["Limita"], path: "Tests/LimitaTests")
    ]
)
