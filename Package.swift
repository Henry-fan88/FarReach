// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FarReach",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FarReach", targets: ["FarReach"]),
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
        .library(name: "RemoteMedia", targets: ["RemoteMedia"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")
    ],
    targets: [
        .target(name: "RemoteCore"),
        .target(name: "RemoteMedia"),
        .executableTarget(name: "FarReach", dependencies: ["RemoteCore", "RemoteMedia", .product(name: "Sparkle", package: "Sparkle")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
        .testTarget(name: "RemoteMediaTests", dependencies: ["RemoteMedia"]),
        .testTarget(name: "FarReachTests", dependencies: ["FarReach", "RemoteCore", "RemoteMedia"])
    ],
    swiftLanguageVersions: [.v5]
)
