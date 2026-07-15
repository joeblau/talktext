// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TalkText",
    platforms: [.macOS(.v14)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "TalkText",
            path: "Sources/TalkText"
        ),
        .testTarget(
            name: "TalkTextTests",
            dependencies: ["TalkText"],
            path: "Tests/TalkTextTests"
        )
    ]
)
