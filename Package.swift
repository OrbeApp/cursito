// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cursito",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CursitoCore"),
        .executableTarget(name: "Cursito", dependencies: ["CursitoCore"]),
        .testTarget(name: "CursitoCoreTests", dependencies: ["CursitoCore"]),
    ]
)
