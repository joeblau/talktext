// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let infoPlistURL = packageDirectory.appendingPathComponent("Info.plist")
let infoPlistData: Data
do {
    infoPlistData = try Data(contentsOf: infoPlistURL)
} catch {
    fatalError("Could not read canonical bundle metadata at \(infoPlistURL.path): \(error)")
}

let infoPlist: [String: Any]
do {
    guard let metadata = try PropertyListSerialization.propertyList(from: infoPlistData, format: nil) as? [String: Any] else {
        fatalError("Canonical bundle metadata at \(infoPlistURL.path) is not a property-list dictionary")
    }
    infoPlist = metadata
} catch {
    fatalError("Could not parse canonical bundle metadata at \(infoPlistURL.path): \(error)")
}

@MainActor func requiredMetadataString(_ key: String) -> String {
    guard let value = infoPlist[key] as? String, !value.isEmpty else {
        fatalError("Canonical bundle metadata at \(infoPlistURL.path) must define a nonempty string \(key)")
    }
    return value
}

let bundleName = requiredMetadataString("CFBundleName")
let executableName = requiredMetadataString("CFBundleExecutable")
let minimumSystemVersion = requiredMetadataString("LSMinimumSystemVersion")

let package = Package(
    name: bundleName,
    platforms: [.macOS(minimumSystemVersion)],
    products: [
        .executable(name: executableName, targets: [executableName]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: executableName,
            path: "Sources/TalkText"
        ),
        .testTarget(
            name: "TalkTextTests",
            dependencies: [.target(name: executableName)],
            path: "Tests/TalkTextTests"
        ),
    ]
)
