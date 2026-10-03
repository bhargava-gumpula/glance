// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Glance",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Glance",
            path: "Sources/Glance",
            linkerSettings: [.linkedFramework("Carbon")]
        )
    ]
)
