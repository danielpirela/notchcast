// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Notchcast",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Notchcast", path: "Sources/Notchcast")
    ]
)
