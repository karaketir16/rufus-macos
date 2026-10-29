// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RufusMac",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RufusCore", targets: ["RufusCore"]),
        .executable(name: "RufusMac", targets: ["RufusMacApp"])
    ],
    targets: [
        .target(name: "RufusCore"),
        .executableTarget(name: "RufusMacApp", dependencies: ["RufusCore"])
    ]
)
