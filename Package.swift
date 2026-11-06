// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Braindump",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Braindump",
            path: "Sources/Braindump"
        )
    ]
)
